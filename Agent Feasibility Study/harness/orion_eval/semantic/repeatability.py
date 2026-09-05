"""Repeatability analysis across N independently-run investigations of the same repository
(Docs/11_phase2_semantic_analysis.md M6).

This module never runs an investigation itself -- `investigate --repeatability` (one
investigation per invocation, run by hand, as many times as wanted) is what produces the
`<out>/repeatability/runN/` directories this module reads back. Deliberately decoupled: N is
whatever actually exists on disk when `repeatability-report` is run, not a number this module
ever decides or loops over itself.
"""
from __future__ import annotations

import json
import statistics
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

from .score import score_components


@dataclass
class RunSummary:
    label: str
    component_count: int
    relationship_count: int
    evidenced_claim_count: int
    uncertainty_count: int
    model_used: str | None
    num_turns: int | None
    total_cost_usd: float | None
    duration_ms: float | None


@dataclass
class PairwiseStability:
    run_a: str
    run_b: str
    matched: int
    missed: int      # component in run_a with no matching component in run_b
    spurious: int     # component in run_b with no matching component in run_a
    macro_f1: float   # 1.0 = the two runs' component decompositions align perfectly


@dataclass
class RepeatabilityReport:
    runs: list[RunSummary] = field(default_factory=list)
    pairs: list[PairwiseStability] = field(default_factory=list)
    mean_pairwise_f1: float | None = None
    min_pairwise_f1: float | None = None
    max_pairwise_f1: float | None = None
    cost_usd: dict[str, float | None] = field(default_factory=dict)
    duration_ms: dict[str, float | None] = field(default_factory=dict)
    num_turns: dict[str, float | None] = field(default_factory=dict)

    def to_dict(self) -> dict[str, Any]:
        return {
            "runs": [vars(r) for r in self.runs],
            "pairs": [vars(p) for p in self.pairs],
            "mean_pairwise_f1": self.mean_pairwise_f1,
            "min_pairwise_f1": self.min_pairwise_f1,
            "max_pairwise_f1": self.max_pairwise_f1,
            "cost_usd": self.cost_usd,
            "duration_ms": self.duration_ms,
            "num_turns": self.num_turns,
        }


def discover_runs(out_dir: Path) -> list[Path]:
    """Every `runN/` under `<out>/repeatability/` that actually has a candidate, sorted
    numerically (`run2` before `run10`, not alphabetically)."""
    base = out_dir / "repeatability"
    if not base.is_dir():
        return []
    dirs = [
        p for p in base.glob("run*")
        if p.is_dir() and p.name[3:].isdigit() and (p / "semantic_findings.json").is_file()
    ]
    return sorted(dirs, key=lambda p: int(p.name[3:]))


def discover_failed_runs(out_dir: Path) -> list[tuple[Path, str]]:
    """`runN/` directories that exist (an `investigate --repeatability` was attempted) but have
    no candidate -- the investigation itself failed (API overload, timeout, non-JSON output,
    ...). Returns `(dir, reason)` so a failed run doesn't just silently vanish from
    `repeatability-report`'s count with no explanation. `reason` is best-effort, pulled from
    the raw wrapper when present."""
    base = out_dir / "repeatability"
    if not base.is_dir():
        return []
    out: list[tuple[Path, str]] = []
    for p in sorted(base.glob("run*"), key=lambda p: int(p.name[3:]) if p.name[3:].isdigit() else 0):
        if not p.is_dir() or not p.name[3:].isdigit():
            continue
        if (p / "semantic_findings.json").is_file():
            continue
        out.append((p, _failure_reason(p)))
    return out


def _failure_reason(run_dir: Path) -> str:
    raw_path = run_dir / "semantic_findings.raw.json"
    if not raw_path.is_file():
        return "no raw wrapper written (crashed before the CLI call completed?)"
    try:
        wrapper = json.loads(raw_path.read_text())
    except json.JSONDecodeError:
        return "raw wrapper is not valid JSON"
    if not isinstance(wrapper, dict):
        return "raw wrapper is not a JSON object"
    status = wrapper.get("api_error_status")
    reason = wrapper.get("terminal_reason") or wrapper.get("subtype") or "unknown"
    result = wrapper.get("result")
    detail = f" ({result[:120]})" if isinstance(result, str) and result else ""
    return f"{reason}" + (f", HTTP {status}" if status else "") + detail


def _load_run(run_dir: Path) -> tuple[dict, dict]:
    candidate = json.loads((run_dir / "semantic_findings.json").read_text())
    meta_path = run_dir / "investigation_meta.json"
    meta = json.loads(meta_path.read_text()) if meta_path.is_file() else {}
    return candidate, meta


def _as_named_anchor_sets(components: list[dict]) -> list[dict]:
    # semantic_findings.json's raw candidate shape uses `members`, not the export's
    # `member_anchors` -- score_components() only cares about `name` + `member_anchors`, so
    # adapt the field name here rather than teaching it two shapes.
    return [{"name": c["name"], "member_anchors": c["members"]} for c in components]


def summarize_run(run_dir: Path) -> RunSummary:
    candidate, meta = _load_run(run_dir)
    return RunSummary(
        label=run_dir.name,
        component_count=len(candidate.get("components", [])),
        relationship_count=len(candidate.get("component_relationships", [])),
        evidenced_claim_count=len(candidate.get("claims", [])),
        uncertainty_count=len(candidate.get("uncertainties", [])),
        model_used=meta.get("model_used"),
        num_turns=meta.get("num_turns"),
        total_cost_usd=meta.get("total_cost_usd"),
        duration_ms=meta.get("duration_ms"),
    )


def pairwise_stability(run_a_dir: Path, run_b_dir: Path, threshold: float = 0.3) -> PairwiseStability:
    """How similar two independent investigations' component decompositions are. Reuses
    `score_components` from the gold-set scorer -- despite the gold/predicted naming there,
    the alignment math (best-match two named anchor-groups against each other by normalized
    Jaccard overlap) is exactly what comparing two runs to each other needs too, just with
    neither side privileged as "ground truth"."""
    cand_a, _ = _load_run(run_a_dir)
    cand_b, _ = _load_run(run_b_dir)
    report = score_components(
        _as_named_anchor_sets(cand_a["components"]),
        _as_named_anchor_sets(cand_b["components"]),
        threshold=threshold,
    )
    return PairwiseStability(
        run_a=run_a_dir.name, run_b=run_b_dir.name,
        matched=len(report.matches), missed=len(report.missed_gold),
        spurious=len(report.spurious_predicted), macro_f1=report.macro_f1,
    )


def _stats(values: list[float | None]) -> dict[str, float | None]:
    clean = [v for v in values if v is not None]
    if not clean:
        return {"min": None, "max": None, "mean": None}
    return {"min": min(clean), "max": max(clean), "mean": statistics.mean(clean)}


def build_report(out_dir: Path, threshold: float = 0.3) -> RepeatabilityReport:
    run_dirs = discover_runs(out_dir)
    report = RepeatabilityReport(runs=[summarize_run(d) for d in run_dirs])

    for i in range(len(run_dirs)):
        for j in range(i + 1, len(run_dirs)):
            report.pairs.append(pairwise_stability(run_dirs[i], run_dirs[j], threshold=threshold))

    if report.pairs:
        f1s = [p.macro_f1 for p in report.pairs]
        report.mean_pairwise_f1 = statistics.mean(f1s)
        report.min_pairwise_f1 = min(f1s)
        report.max_pairwise_f1 = max(f1s)

    report.cost_usd = _stats([r.total_cost_usd for r in report.runs])
    report.duration_ms = _stats([r.duration_ms for r in report.runs])
    report.num_turns = _stats([r.num_turns for r in report.runs])

    return report
