#!/usr/bin/env bash
# Regenerates OrionMobile/Resources/starlette-ask-bench.json (Docs/19 M6): the 55 Starlette
# benchmark questions (id, category, question -- no answers; grading happens on the Mac against
# benchmark.json) for the on-device Ask benchmark.
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
src="$here/../Agent Feasibility Study/benchmark/benchmark.json"
python3 - "$src" "$here/OrionMobile/Resources/starlette-ask-bench.json" <<'PY'
import json, sys
qs = json.load(open(sys.argv[1]))["questions"]
out = [{"id": q["id"], "category": q["category"], "question": q["question"]} for q in qs]
json.dump(out, open(sys.argv[2], "w"), indent=1)
print(f"wrote {len(out)} questions to {sys.argv[2]}")
PY
