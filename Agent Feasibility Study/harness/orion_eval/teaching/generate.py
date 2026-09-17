"""Offline prompt-iteration helper for Phase 7 teaching-question generation
(Docs/17_phase7_teaching_mode.md §6). **Not wired into anything** — the real generator is
`TeachingQuestionGenerator` in Swift (`OrionMacOs/Sources/OrionAgent/Teaching/`), and the real
verification/persistence is `TeachingQuestionVerifier` in `OrionCodeIntel`. This module exists
only so a prompt can be tweaked and eyeballed against a real concept without rebuilding the
Swift binary — the same "port, don't extend the Python side" posture Phase 3 set (Docs/12
Decision 3), kept here for experimentation rather than as a component.

Mirrors `TeachingSchema.promptHint` / `TeachingSchema.cliJSONSchema()` field-for-field; keep the
two in sync by hand.

Usage:
    python -m orion_eval.teaching.generate --concept concept.json [--band N] [--run]

`concept.json`: {"id": "...", "kind": "component", "subject_label": "...",
                 "evidence_lines": ["<anchor> — <signature>"], "related": ["<label>", ...]}
`--run` shells an authenticated `claude` the same way `semantic/investigate.py` does.
"""
from __future__ import annotations

import argparse
import json
import subprocess
import sys
from pathlib import Path
from typing import Any

SCHEMA_VERSION = "phase7.v1"
MIN_REFERENCE_ANSWER_CHARS = 20
MIN_CRITERION_CHARS = 8

_ANCHORS = {"type": "array", "items": {"type": "string", "minLength": 1}}
_CRITERION = {
    "type": "object",
    "required": ["kind", "text", "evidence"],
    "additionalProperties": False,
    "properties": {
        "kind": {"enum": ["required", "bonus"]},
        "text": {"type": "string", "minLength": MIN_CRITERION_CHARS},
        "evidence": _ANCHORS,
    },
}
_ANTI = {
    "type": "object",
    "required": ["text", "evidence"],
    "additionalProperties": False,
    "properties": {
        "text": {"type": "string", "minLength": MIN_CRITERION_CHARS},
        "evidence": _ANCHORS,
    },
}
TEACHING_QUESTION_SCHEMA: dict[str, Any] = {
    "type": "object",
    "required": [
        "schema_version", "concept_id", "difficulty_band", "explain", "question",
        "reference_answer", "reference_anchors", "rubric", "anti_criteria",
    ],
    "additionalProperties": False,
    "properties": {
        "schema_version": {"const": SCHEMA_VERSION},
        "concept_id": {"type": "string", "minLength": 1},
        "difficulty_band": {"type": "integer", "minimum": 1, "maximum": 3},
        "explain": {"type": "string", "minLength": 1},
        "question": {"type": "string", "minLength": 1},
        "reference_answer": {"type": "string", "minLength": MIN_REFERENCE_ANSWER_CHARS},
        "reference_anchors": _ANCHORS,
        "rubric": {"type": "array", "minItems": 1, "items": _CRITERION},
        "anti_criteria": {"type": "array", "items": _ANTI},
        "transfer_problem": {"type": "string"},
    },
}

SCHEMA_HINT = json.dumps(
    {
        "schema_version": SCHEMA_VERSION,
        "concept_id": "<the concept id you were given, verbatim>",
        "difficulty_band": 1,
        "explain": "<2-3 sentences that set up the question without answering it>",
        "question": "<the question to pose to the developer>",
        "reference_answer": "<concise model answer, <=120 words; every factual clause backed by an anchor>",
        "reference_anchors": ["<path>::<Dotted.Name>", "..."],
        "rubric": [
            {"kind": "required", "text": "<one single, checkable fact>", "evidence": ["<path>::<Dotted.Name>"]},
            {"kind": "bonus", "text": "<worthwhile but not essential>", "evidence": ["..."]},
        ],
        "anti_criteria": [
            {"text": "<a statement that would reveal a WRONG mental model>", "evidence": ["..."]}
        ],
        "transfer_problem": "<a harder follow-up to try next, not graded here>",
    },
    indent=2,
)

_BAND_GUIDANCE = {
    1: "Band 1 — RECALL. State/define what this concept is or does. One hop: its own code only.",
    2: "Band 2 — COMPREHENSION. Explain how it relates to or differs from a neighbour, or a "
    "dependency's direction. Two hops.",
    3: "Band 3 — TRANSFER. A change-impact / novel-scenario question. Three or more hops.",
}


def build_prompt(concept: dict[str, Any], band: int) -> str:
    lines = "".join(f"\n  - {line}" for line in concept.get("evidence_lines", []))
    related = concept.get("related", []) if band >= 2 else []
    related_block = ""
    if related:
        related_block = "\n\nNeighbouring concepts you may contrast against:" + "".join(
            f"\n  - {r}" for r in related
        )
    return f"""You are generating ONE teaching question for a developer learning an unfamiliar \
Python codebase (Orion teaching mode, Docs/05 Stage 7). You produce a question, a concise \
reference answer, an atomic grading rubric, and misconception anti-criteria — all grounded in \
specific code. You are NOT teaching or answering.

Concept to teach (id {concept['id']}, kind {concept.get('kind', '?')}):
  {concept.get('subject_label', '')}

{_BAND_GUIDANCE.get(band, _BAND_GUIDANCE[1])}

Grounding — cite anchors verbatim from this list ("<path>::<Dotted.Name>"); inventing or \
misspelling one rejects the whole question:{lines}{related_block}

Rules: each `required` criterion is ONE checkable fact (3-6 of them); `bonus` 0-3; \
`anti_criteria` 1-3 are statements revealing a WRONG mental model; every criterion cites an \
anchor; `reference_answer` <=120 words, every clause anchor-backed.

Return EXACTLY one JSON object, nothing else (schema_version must be "{SCHEMA_VERSION}", \
concept_id must be "{concept['id']}", difficulty_band must be {band}):
{SCHEMA_HINT}
"""


def build_command(prompt: str, *, repo: Path, export_dir: Path, model: str, max_budget_usd: float) -> list[str]:
    return [
        "claude", "-p",
        "--output-format", "json",
        "--model", model,
        "--tools", "Read,Grep,Glob",
        "--permission-mode", "bypassPermissions",
        "--max-budget-usd", str(max_budget_usd),
        "--add-dir", str(export_dir),
        "--json-schema", json.dumps(TEACHING_QUESTION_SCHEMA),
        "--no-session-persistence",
        prompt,
    ]


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--concept", required=True, type=Path)
    ap.add_argument("--band", type=int, default=None)
    ap.add_argument("--run", action="store_true", help="shell an authenticated `claude`")
    ap.add_argument("--repo", type=Path, default=Path("."))
    ap.add_argument("--export-dir", type=Path, default=Path(".orion/export"))
    ap.add_argument("--model", default="claude-sonnet-5")
    ap.add_argument("--max-budget-usd", type=float, default=0.50)
    args = ap.parse_args(argv)

    concept = json.loads(args.concept.read_text())
    band = args.band or 1
    prompt = build_prompt(concept, band)

    if not args.run:
        print(prompt)
        return 0

    cmd = build_command(
        prompt, repo=args.repo, export_dir=args.export_dir, model=args.model,
        max_budget_usd=args.max_budget_usd,
    )
    proc = subprocess.run(cmd, cwd=args.repo, capture_output=True, text=True, timeout=400)
    if proc.returncode != 0:
        sys.stderr.write(proc.stderr)
        return proc.returncode
    try:
        wrapper = json.loads(proc.stdout)
        out = wrapper.get("structured_output") or wrapper.get("result")
        print(json.dumps(out, indent=2) if isinstance(out, dict) else out)
    except json.JSONDecodeError:
        print(proc.stdout)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
