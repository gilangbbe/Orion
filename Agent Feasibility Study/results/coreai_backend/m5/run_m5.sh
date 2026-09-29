#!/usr/bin/env bash
# Docs/18 M5 (short run) -- guided-generation grading on Core AI vs M4's thinking text judge, on
# the same 6-item gold subset, k=3, pairwise. Local, $0. Resumable; fresh DB copy per run.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../../.." && pwd)"
STUDY="$ROOT/Agent Feasibility Study"
REPO="$STUDY/vendor/starlette"
GOLD="$HERE/../m4/teach_subset6.gold.json"
BIN="$ROOT/OrionMacOs/.build/release/orion-agent"
COPIES="${TMPDIR:-/tmp}/orion-m5-dbs"
STATUS="$HERE/status.log"

[[ -x "$BIN" ]] || { echo "build first: swift build -c release --product orion-agent" >&2; exit 2; }

for v in qwen3-8b-4bit qwen3-4b-4bit; do
    name="teach_guided_$v"
    if [[ -e "$HERE/$name/teaching_calibration_summary.json" ]]; then
        echo "$(date '+%F %T') SKIP  $name" | tee -a "$STATUS"; continue
    fi
    dest="$COPIES/$name"; rm -rf "${dest:?}"; mkdir -p "$COPIES"; cp -R "$REPO/.orion" "$dest"
    echo "$(date '+%F %T') START $name" | tee -a "$STATUS"
    start=$(date +%s)
    ORION_LOCAL_ROLES="*=$v" "$BIN" teach bench "$REPO" --gold "$GOLD" --out "$dest" --pairwise \
        --local-backend coreai --judge-output guided --report-dir "$HERE/$name" > "$HERE/$name.log" 2>&1
    echo "$(date '+%F %T') END   $name rc=$? $(( $(date +%s) - start ))s" | tee -a "$STATUS"
done
echo "$(date '+%F %T') ALL DONE" | tee -a "$STATUS"
