"""Aggregate one or more results/<run>/ directories into a Markdown leaderboard.

Source of truth is results/<run>/{answers,grades}.jsonl + run_meta.json, so the leaderboard
does not need the MLflow server running.
"""
from __future__ import annotations

import json
import statistics as stats
from pathlib import Path
from typing import Any

AXES = ["correctness", "completeness", "architectural_reasoning", "hallucination",
        "evidence_accuracy", "structured_output"]
CATS = ["code_understanding", "cross_file_reasoning", "architecture",
        "dependency_change_impact", "behavioral_reasoning", "contradiction_detection",
        "evidence", "teaching", "transfer"]


def _mean(xs: list[Any]) -> float | None:
    xs = [x for x in xs if isinstance(x, (int, float)) and not isinstance(x, bool)]
    return stats.fmean(xs) if xs else None


def _load_run(run_dir: Path) -> dict:
    meta = json.loads((run_dir / "run_meta.json").read_text())
    answers = [json.loads(l) for l in (run_dir / "answers.jsonl").read_text().splitlines() if l.strip()]
    grades_path = run_dir / "grades.jsonl"
    grades = ([json.loads(l) for l in grades_path.read_text().splitlines() if l.strip()]
              if grades_path.is_file() else [])
    return {"meta": meta, "answers": answers, "grades": grades, "name": run_dir.name}


def _fmt(x: float | None, nd: int = 2) -> str:
    return "—" if x is None else f"{x:.{nd}f}"


def build_leaderboard(run_dirs: list[str | Path], out_path: str | Path) -> str:
    runs = [_load_run(Path(d)) for d in run_dirs]
    lines: list[str] = []
    A = lines.append

    A("# Task 3 — Baseline LLM Leaderboard\n")
    m0 = runs[0]["meta"]
    A(f"- Benchmark: **{m0.get('repository')} {m0.get('version')}** "
      f"@ `{m0.get('commit_sha', '')[:12]}` · {m0.get('n_questions', '?')} questions")
    A(f"- Hardware: {m0.get('hardware', '?')}")
    A(f"- Runtime: mlx-lm {m0.get('mlx_lm_version', '?')}")
    judges = sorted({r['meta'].get('judge', 'none') for r in runs})
    A(f"- Judge(s): {', '.join(judges)}")
    A(f"- Runs aggregated: {', '.join(r['name'] for r in runs)}\n")
    if any(r["meta"].get("judge", "none") in ("none",) or "mlx:" in r["meta"].get("judge", "")
           for r in runs):
        A("> ⚠️ Some rows graded with **no judge** or a **provisional local judge**. "
          "correctness / architectural_reasoning / teaching_quality on those rows are "
          "fallback or weak-judge estimates — re-grade with a strong judge before drawing "
          "model-selection conclusions.\n")

    # ---- main table
    A("## Overall\n")
    hdr = ["model", "quant", "composite", *AXES, "teaching_q", "struct_valid%",
           "load_s", "ttft_s", "gen_tps", "peak_GB"]
    A("| " + " | ".join(hdr) + " |")
    A("|" + "|".join(["---"] * len(hdr)) + "|")
    rows = []
    for r in runs:
        g, a, meta = r["grades"], r["answers"], r["meta"]
        row = {
            "model": meta.get("model_id", r["name"]),
            "quant": meta.get("quant", ""),
            "composite": _mean([x.get("composite") for x in g]),
            "struct_valid": sum(1 for x in a if x.get("schema_valid")) / max(len(a), 1) * 100,
            "load_s": meta.get("load_seconds"),
            "ttft_s": _mean([x.get("ttft_seconds") for x in a]),
            "gen_tps": _mean([x.get("gen_tps") for x in a]),
            "peak_GB": _mean([x.get("peak_memory_gb") for x in a]),
        }
        for ax in AXES:
            row[ax] = _mean([x.get(ax) for x in g])
        row["teaching_quality"] = _mean([x.get("teaching_quality") for x in g])
        rows.append(row)
    rows.sort(key=lambda x: (x["composite"] is None, -(x["composite"] or 0)))
    for row in rows:
        A("| " + " | ".join([
            f"**{row['model']}**", row["quant"], _fmt(row["composite"], 3),
            *[_fmt(row[ax]) for ax in AXES],
            _fmt(row["teaching_quality"]), _fmt(row["struct_valid"], 0),
            _fmt(row["load_s"], 1), _fmt(row["ttft_s"], 2), _fmt(row["gen_tps"], 1),
            _fmt(row["peak_GB"], 2),
        ]) + " |")
    A("\n_Axis scale 0–2 (higher better). hallucination: 2 = clean, 0 = fabricates. "
      "composite = mean of the 6 axes present, normalised to 0–1._\n")

    # ---- per-category composite
    A("## Composite by category\n")
    hdr2 = ["model", *[c.replace("_", " ") for c in CATS]]
    A("| " + " | ".join(hdr2) + " |")
    A("|" + "|".join(["---"] * len(hdr2)) + "|")
    for r in runs:
        by: dict[str, list[float]] = {}
        for x in r["grades"]:
            if isinstance(x.get("composite"), (int, float)):
                by.setdefault(x["category"], []).append(x["composite"])
        A("| " + " | ".join([f"**{r['meta'].get('model_id', r['name'])}**",
                             *[_fmt(_mean(by.get(c, [])), 2) for c in CATS]]) + " |")

    # ---- capability signal
    A("\n## Reasoning-vs-plausibility signal\n")
    A("Heuristic only. A model that *reasons* should score similarly on hard cross-file / "
      "behavioural / change-impact items as on easy code-understanding items, keep "
      "hallucination high, and cite real evidence. A model that merely *sounds right* shows a "
      "large easy→hard drop and/or low evidence_accuracy with high verbal completeness.\n")
    A("| model | easy composite | hard composite | drop | mean hallucination | mean evidence_acc | "
      "concept_coverage |")
    A("|---|---|---|---|---|---|---|")
    for r in runs:
        g = r["grades"]
        easy = _mean([x.get("composite") for x in g if x.get("difficulty") == "easy"])
        hard = _mean([x.get("composite") for x in g if x.get("difficulty") == "hard"])
        drop = None if (easy is None or hard is None) else easy - hard
        A("| " + " | ".join([
            f"**{r['meta'].get('model_id', r['name'])}**", _fmt(easy, 3), _fmt(hard, 3),
            _fmt(drop, 3),
            _fmt(_mean([x.get('hallucination') for x in g])),
            _fmt(_mean([x.get('evidence_accuracy') for x in g])),
            _fmt(_mean([x.get('concept_coverage') for x in g])),
        ]) + " |")

    out = Path(out_path)
    out.write_text("\n".join(lines) + "\n")
    return str(out)
