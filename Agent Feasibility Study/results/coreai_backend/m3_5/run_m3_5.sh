#!/usr/bin/env bash
# HISTORICAL (Docs/18 M6): `--tool-protocol` was removed with the JSON-action loop; native tool
# calling is now the only depth-2 path, so today's equivalent is the same command without that flag.
# Docs/18 M3.5 gate -- depth 2 on Core AI with native FoundationModels tool calling, all 55
# questions, compared against M3's bench_d2_coreai (json) and bench_d2_mlx baselines. Local, $0.
# Resumable: skipped when its summary already exists.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../../.." && pwd)"
STUDY="$ROOT/Agent Feasibility Study"
REPO="$STUDY/vendor/starlette"
QUESTIONS="$STUDY/benchmark/benchmark.resolved.json"
BIN="$ROOT/OrionMacOs/.build/release/orion-agent"   # plain SwiftPM: the Core AI path needs no xcodebuild
COPY="${TMPDIR:-/tmp}/orion-m3_5-dbs/bench_d2_coreai_native"
STATUS="$HERE/status.log"

[[ -x "$BIN" ]] || { echo "build first: swift build -c release --product orion-agent" >&2; exit 2; }
if [[ -f "$HERE/bench_d2_coreai_native/routing_benchmark_summary.json" ]]; then
    echo "$(date '+%F %T') SKIP  bench_d2_coreai_native (already has results)" | tee -a "$STATUS"; exit 0
fi

rm -rf "${COPY:?}" && mkdir -p "$(dirname "$COPY")" && cp -R "$REPO/.orion" "$COPY"
echo "$(date '+%F %T') START bench_d2_coreai_native" | tee -a "$STATUS"
start=$(date +%s)
"$BIN" bench "$REPO" --questions "$QUESTIONS" --out "$COPY" --force-depth 2 \
    --local-backend coreai --tool-protocol native --report-dir "$HERE/bench_d2_coreai_native" \
    > "$HERE/bench_d2_coreai_native.log" 2>&1
echo "$(date '+%F %T') END   bench_d2_coreai_native rc=$? $(( $(date +%s) - start ))s" | tee -a "$STATUS"
