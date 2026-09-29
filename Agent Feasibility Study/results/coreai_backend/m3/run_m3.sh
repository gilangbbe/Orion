#!/usr/bin/env bash
# HISTORICAL (Docs/18 M6): MLX was removed after the M3 gate, so the `--local-backend mlx` steps
# below can no longer run. Kept as the record of how M3's MLX-vs-Core AI numbers were produced.
# Docs/18 M3 -- MLX vs Core AI head-to-head (Qwen3-8B 4-bit), all local, no API cost.
# Sequential on purpose: one model per process (peak memory is that backend's alone) and no two
# runs competing for the GPU. Every run that writes to the database gets its own fresh copy of the
# vendored Starlette .orion, so both backends start from identical state.
#
#   ./run_m3.sh            # everything (~7 h on an M5); resumable -- see below
#   ./run_m3.sh model      # just model-bench
#
# Resumable: a step whose result file already exists is skipped, so re-running after an
# interruption only does what's missing. Delete a step's result directory to redo it.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../../.." && pwd)"
STUDY="$ROOT/Agent Feasibility Study"
REPO="$STUDY/vendor/starlette"
QUESTIONS="$STUDY/benchmark/benchmark.resolved.json"
GOLD="$STUDY/benchmark/starlette_teaching_grader.gold.json"
BIN="$ROOT/OrionMacOs/.build/xcodebuild/Build/Products/Release/orion-agent"
COPIES="${TMPDIR:-/tmp}/orion-m3-dbs"
STATUS="$HERE/status.log"
only="${1:-all}"

[[ -x "$BIN" ]] || { echo "build first: xcodebuild -scheme orion-agent -configuration Release ..." >&2; exit 2; }

step() {  # step <name> <cmd...>
    local name="$1"; shift
    echo "$(date '+%F %T') START $name" | tee -a "$STATUS"
    local start=$(date +%s)
    "$@" > "$HERE/$name.log" 2>&1
    local rc=$?
    echo "$(date '+%F %T') END   $name rc=$rc $(( $(date +%s) - start ))s" | tee -a "$STATUS"
}

fresh_copy() {  # fresh_copy <name> -> prints the copy's path
    local dest="$COPIES/$1"
    rm -rf "${dest:?}"
    mkdir -p "$COPIES"
    cp -R "$REPO/.orion" "$dest"
    echo "$dest"
}

done_already() {  # done_already <result file>
    if [[ -f "$1" ]]; then echo "$(date '+%F %T') SKIP  $(basename "$(dirname "$1")") (already has results)" | tee -a "$STATUS"; return 0; fi
    return 1
}

for backend in mlx coreai; do
    [[ $only == all || $only == model ]] || break
    ls "$HERE/model_bench"/model_bench_"$backend"_* >/dev/null 2>&1 && { done_already "$(ls "$HERE/model_bench"/model_bench_"$backend"_* | head -1)"; continue; }
    step "model_bench_$backend" "$BIN" model-bench "$REPO" --local-backend "$backend" \
        --trials 3 --max-tokens 256 --report-dir "$HERE/model_bench"
done

for depth in 2 1; do
    [[ $only == all || $only == bench ]] || break
    for backend in mlx coreai; do
        done_already "$HERE/bench_d${depth}_$backend/routing_benchmark_summary.json" && continue
        db=$(fresh_copy "bench_d${depth}_$backend")
        step "bench_d${depth}_$backend" "$BIN" bench "$REPO" --questions "$QUESTIONS" --out "$db" \
            --force-depth "$depth" --local-backend "$backend" --report-dir "$HERE/bench_d${depth}_$backend"
    done
done

for backend in mlx coreai; do
    [[ $only == all || $only == teach ]] || break
    done_already "$HERE/teach_$backend/teaching_calibration_summary.json" && continue
    db=$(fresh_copy "teach_$backend")
    step "teach_$backend" "$BIN" teach bench "$REPO" --gold "$GOLD" --out "$db" --pairwise \
        --local-backend "$backend" --report-dir "$HERE/teach_$backend"
done

echo "$(date '+%F %T') ALL DONE" | tee -a "$STATUS"
