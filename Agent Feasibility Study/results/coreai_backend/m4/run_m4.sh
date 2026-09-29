#!/usr/bin/env bash
# Docs/18 M4 (short run) -- per-role model selection on Core AI. Local, $0. Resumable: a step whose
# result file exists is skipped. One model per process, strictly sequential, fresh DB copy per run.
#
# Configs are set through ORION_LOCAL_ROLES="*=<variant>:<on|off>", the same mechanism production uses.
#   model   raw runtime per variant (model-bench, 1 trial)                 3 runs
#   answer  depth 2, native tools, the 10 hand-graded questions            5 runs (8b:on reused from M3.5)
#   teach   judge + pairwise comparer, 6-item gold subset, k=3             4 runs (no INT8-KV: short prompts)
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../../.." && pwd)"
STUDY="$ROOT/Agent Feasibility Study"
REPO="$STUDY/vendor/starlette"
BIN="$ROOT/OrionMacOs/.build/release/orion-agent"
COPIES="${TMPDIR:-/tmp}/orion-m4-dbs"
STATUS="$HERE/status.log"
only="${1:-all}"

V8=qwen3-8b-4bit
V8KV=qwen3-8b-4bit_weights_8bit_kv_cache
V4=qwen3-4b-4bit

[[ -x "$BIN" ]] || { echo "build first: swift build -c release --product orion-agent" >&2; exit 2; }

step() {  # step <name> <result file> <cmd...>
    local name="$1" result="$2"; shift 2
    if [[ -e "$result" ]]; then echo "$(date '+%F %T') SKIP  $name" | tee -a "$STATUS"; return; fi
    echo "$(date '+%F %T') START $name" | tee -a "$STATUS"
    local start=$(date +%s)
    "$@" > "$HERE/$name.log" 2>&1
    echo "$(date '+%F %T') END   $name rc=$? $(( $(date +%s) - start ))s" | tee -a "$STATUS"
}

fresh_copy() {
    local dest="$COPIES/$1"
    rm -rf "${dest:?}" && mkdir -p "$COPIES" && cp -R "$REPO/.orion" "$dest" && echo "$dest"
}

if [[ $only == all || $only == model ]]; then
    for v in $V8 $V8KV $V4; do
        step "model_$v" "$HERE/model/$v.done" \
            bash -c "\"$BIN\" model-bench \"$REPO\" --local-backend coreai:$v --trials 1 --max-tokens 256 \
                --report-dir \"$HERE/model\" && touch \"$HERE/model/$v.done\""
    done
fi

if [[ $only == all || $only == answer ]]; then
    for cfg in $V8:off $V8KV:on $V8KV:off $V4:on $V4:off; do
        name="answer_${cfg/:/_}"
        db=$(fresh_copy "$name")
        step "$name" "$HERE/$name/routing_benchmark_summary.json" \
            env ORION_LOCAL_ROLES="*=$cfg" "$BIN" bench "$REPO" --questions "$HERE/questions_hand_graded10.json" \
                --out "$db" --force-depth 2 --local-backend coreai --report-dir "$HERE/$name"
    done
fi

if [[ $only == all || $only == teach ]]; then
    for cfg in $V8:on $V8:off $V4:on $V4:off; do
        name="teach_${cfg/:/_}"
        db=$(fresh_copy "$name")
        step "$name" "$HERE/$name/teaching_calibration_summary.json" \
            env ORION_LOCAL_ROLES="*=$cfg" "$BIN" teach bench "$REPO" --gold "$HERE/teach_subset6.gold.json" \
                --out "$db" --pairwise --local-backend coreai --report-dir "$HERE/$name"
    done
fi

echo "$(date '+%F %T') ALL DONE" | tee -a "$STATUS"
