"""Gold-set scorer (Docs/11_phase2_semantic_analysis.md M5).

Two independent axes:
  * Component alignment -- greedy best-match gold<->predicted by Jaccard overlap of member
    anchor sets, then per-match precision/recall/F1; unmatched gold = missed (an architectural
    area Claude didn't surface at all), unmatched predicted = spurious (over-fragmentation or
    a hallucinated grouping).
  * Evidence accuracy -- reuses the Swift-side `SemanticImporter` verification signal already
    recorded on each persisted claim (`claim_type == "CONTRADICTED"`), read back from the
    export. Not re-derived here -- Swift is the side with the real Code Graph.

The optional LLM-judge axis from the original Docs/11 plan (rate each matched component's
architectural_role plausibility via the `anthropic:claude-sonnet-5` judge, mirroring
`grade.py`) is a documented stretch item and is **not built** here -- it costs real API calls
per run and isn't needed for the pipeline to be considered working.
"""
from __future__ import annotations

import json
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

MATCH_THRESHOLD = 0.3   # Jaccard overlap needed to count two components as "the same"


def normalize_anchor(anchor: str) -> str:
    """Roll an anchor up to its top-level defining symbol: `path::Class.method` ->
    `path::Class`; a bare module path is unchanged. The gold set is authored at module/class
    granularity only (Docs/11 M5); a predicted component routinely cites individual methods --
    normalizing both sides to the same granularity is what makes the overlap comparison mean
    something, instead of penalizing a prediction for being *more* specific than gold."""
    if "::" not in anchor:
        return anchor
    path, dotted = anchor.split("::", 1)
    top = dotted.split(".", 1)[0]
    return f"{path}::{top}"


def _normalized_set(anchors: list[str]) -> set[str]:
    return {normalize_anchor(a) for a in anchors}


def jaccard(a: set[str], b: set[str]) -> float:
    if not a and not b:
        return 1.0
    union = a | b
    return len(a & b) / len(union) if union else 0.0


@dataclass
class ComponentMatch:
    gold_name: str
    predicted_name: str
    jaccard: float
    precision: float
    recall: float
    f1: float
    gold_only: list[str]        # normalized anchors gold has that the prediction doesn't
    predicted_only: list[str]   # normalized anchors the prediction has that gold doesn't


@dataclass
class ScoreReport:
    matches: list[ComponentMatch] = field(default_factory=list)
    missed_gold: list[str] = field(default_factory=list)
    spurious_predicted: list[str] = field(default_factory=list)
    macro_precision: float = 0.0
    macro_recall: float = 0.0
    macro_f1: float = 0.0
    evidenced_claim_count: int = 0
    contradicted_claim_count: int = 0
    evidence_accuracy: float | None = None

    def to_dict(self) -> dict[str, Any]:
        return {
            "matches": [vars(m) for m in self.matches],
            "missed_gold": self.missed_gold,
            "spurious_predicted": self.spurious_predicted,
            "macro_precision": self.macro_precision,
            "macro_recall": self.macro_recall,
            "macro_f1": self.macro_f1,
            "evidenced_claim_count": self.evidenced_claim_count,
            "contradicted_claim_count": self.contradicted_claim_count,
            "evidence_accuracy": self.evidence_accuracy,
        }


def score_components(
    gold: list[dict], predicted: list[dict], threshold: float = MATCH_THRESHOLD
) -> ScoreReport:
    """Greedy best-match alignment: repeatedly take the highest-Jaccard (gold, predicted) pair
    at or above `threshold` that hasn't used either side yet. Whatever's left unmatched on
    either side is missed/spurious -- both are informative failure modes, reported separately
    rather than folded into a single score."""
    gold_sets = {c["name"]: _normalized_set(c["member_anchors"]) for c in gold}
    pred_sets = {c["name"]: _normalized_set(c["member_anchors"]) for c in predicted}

    pairs: list[tuple[float, str, str]] = []
    for g_name, g_set in gold_sets.items():
        for p_name, p_set in pred_sets.items():
            j = jaccard(g_set, p_set)
            if j >= threshold:
                pairs.append((j, g_name, p_name))
    pairs.sort(key=lambda t: t[0], reverse=True)

    used_gold: set[str] = set()
    used_pred: set[str] = set()
    report = ScoreReport()
    for j, g_name, p_name in pairs:
        if g_name in used_gold or p_name in used_pred:
            continue
        used_gold.add(g_name)
        used_pred.add(p_name)
        g_set, p_set = gold_sets[g_name], pred_sets[p_name]
        inter = g_set & p_set
        precision = len(inter) / len(p_set) if p_set else 0.0
        recall = len(inter) / len(g_set) if g_set else 0.0
        f1 = 2 * precision * recall / (precision + recall) if (precision + recall) else 0.0
        report.matches.append(ComponentMatch(
            gold_name=g_name, predicted_name=p_name, jaccard=j,
            precision=precision, recall=recall, f1=f1,
            gold_only=sorted(g_set - p_set), predicted_only=sorted(p_set - g_set),
        ))

    report.missed_gold = sorted(set(gold_sets) - used_gold)
    report.spurious_predicted = sorted(set(pred_sets) - used_pred)

    if report.matches:
        n = len(report.matches)
        report.macro_precision = sum(m.precision for m in report.matches) / n
        report.macro_recall = sum(m.recall for m in report.matches) / n
        report.macro_f1 = sum(m.f1 for m in report.matches) / n

    return report


def score_evidence(claims: list[dict]) -> tuple[int, int, float | None]:
    """`claims` is `claims.jsonl`'s rows. `UNKNOWN` (uncertainty-derived, evidence-free) claims
    are excluded -- they were never a checkable assertion. Returns
    (evidenced_count, contradicted_count, accuracy | None if there were no evidenced claims)."""
    evidenced = [c for c in claims if c["claim_type"] != "UNKNOWN"]
    contradicted = [c for c in evidenced if c["claim_type"] == "CONTRADICTED"]
    accuracy = 1 - (len(contradicted) / len(evidenced)) if evidenced else None
    return len(evidenced), len(contradicted), accuracy


def score(gold_path: Path, export_dir: Path, threshold: float = MATCH_THRESHOLD) -> ScoreReport:
    gold = json.loads(gold_path.read_text())["components"]
    predicted_rows = [
        json.loads(line)
        for line in (export_dir / "components.jsonl").read_text().splitlines()
        if line.strip()
    ]
    # components.jsonl already uses `member_anchors`, matching the gold file's own field name.
    predicted = [{"name": c["name"], "member_anchors": c["member_anchors"]} for c in predicted_rows]

    report = score_components(gold, predicted, threshold=threshold)

    claims_path = export_dir / "claims.jsonl"
    if claims_path.is_file():
        claims = [json.loads(line) for line in claims_path.read_text().splitlines() if line.strip()]
        report.evidenced_claim_count, report.contradicted_claim_count, report.evidence_accuracy = (
            score_evidence(claims)
        )

    return report
