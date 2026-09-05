"""The Phase 2 structured-output contract, `schema_version` "phase2.v1"
(Docs/11_phase2_semantic_analysis.md "Structured output contract"). Mirrors the Swift-side
`SemanticFindings` Decodable types in
`OrionMacOs/Sources/OrionCodeIntel/Semantic/SemanticFindings.swift` field-for-field — keep the
two in sync by hand; this is intentionally not codegen'd, there are only five fields.

This module is a coarse Python-side pre-filter (Docs/11 pipeline step 1 only). It is not the
authority: `SemanticImporter` in Swift re-checks schema_version and does the real evidence
(step 2) and consistency (step 3) validation against the actual Code Graph. Nothing here is
ever treated as ground truth (Docs/01 non-goals).
"""
from __future__ import annotations

import json
from typing import Any

import jsonschema

from ..schema import extract_json  # reuse the existing clean/fenced/braces recovery

SCHEMA_VERSION = "phase2.v1"

SEMANTIC_SCHEMA: dict[str, Any] = {
    "$schema": "https://json-schema.org/draft/2020-12/schema",
    "type": "object",
    "required": ["schema_version", "components", "component_relationships", "claims", "uncertainties"],
    "additionalProperties": False,
    "properties": {
        "schema_version": {"const": SCHEMA_VERSION},
        "components": {
            "type": "array",
            "items": {
                "type": "object",
                "required": ["name", "members"],
                "additionalProperties": False,
                "properties": {
                    "name": {"type": "string", "minLength": 1},
                    "description": {"type": ["string", "null"]},
                    "architectural_role": {"type": ["string", "null"]},
                    "members": {
                        "type": "array",
                        "items": {"type": "string", "minLength": 1},
                        "minItems": 1,
                    },
                },
            },
        },
        "component_relationships": {
            "type": "array",
            "items": {
                "type": "object",
                "required": ["source", "target", "type"],
                "additionalProperties": False,
                "properties": {
                    "source": {"type": "string", "minLength": 1},
                    "target": {"type": "string", "minLength": 1},
                    "type": {"type": "string", "minLength": 1},
                },
            },
        },
        "claims": {
            "type": "array",
            "items": {
                "type": "object",
                "required": ["claim_type", "statement", "evidence", "confidence"],
                "additionalProperties": False,
                "properties": {
                    # FACT and CONTRADICTED are deliberately absent -- Claude never self-tags
                    # either (Docs/11: FACT is Phase 1's, CONTRADICTED is a Swift-side verdict).
                    "claim_type": {"enum": ["INTERPRETATION", "INFERENCE", "UNKNOWN"]},
                    "statement": {"type": "string", "minLength": 1},
                    "evidence": {"type": "array", "items": {"type": "string", "minLength": 1}},
                    "confidence": {"enum": ["high", "medium", "low", "unresolved"]},
                },
            },
        },
        "uncertainties": {"type": "array", "items": {"type": "string", "minLength": 1}},
    },
}

# Given verbatim to the model as its target shape (and used to build --json-schema for the
# `claude` CLI's structured-output enforcement -- see investigate.py).
SCHEMA_HINT = json.dumps(
    {
        "schema_version": SCHEMA_VERSION,
        "components": [{
            "name": "<short component name>",
            "description": "<what it does, one or two sentences>",
            "architectural_role": "<e.g. core | supporting>",
            "members": ["<path>::<Dotted.Name>", "..."],
        }],
        "component_relationships": [
            {"source": "<component name>", "target": "<component name>", "type": "depends_on"}
        ],
        "claims": [{
            "claim_type": "INTERPRETATION | INFERENCE | UNKNOWN",
            "statement": "<a specific, evidence-backed claim>",
            "evidence": ["<path>::<Dotted.Name>", "..."],
            "confidence": "high | medium | low | unresolved",
        }],
        "uncertainties": ["<something architecturally important you could not ground in evidence>"],
    },
    indent=2,
)


def cli_json_schema() -> dict[str, Any]:
    """`SEMANTIC_SCHEMA` without `$schema`, for the `claude --json-schema` flag specifically.

    That flag's own validator doesn't have the 2020-12 meta-schema registered offline and
    fails upfront (before calling the model) when `$schema` names it explicitly: "not a valid
    JSON Schema: no schema with key or ref ...draft/2020-12/schema". Every keyword this schema
    actually uses (type/required/additionalProperties/properties/const/enum/minLength/
    minItems) is unchanged across drafts, so dropping the dialect declaration for the CLI copy
    doesn't change what's accepted -- only `jsonschema.Draft202012Validator` (our own
    Python-side check in `validate_semantic`) needs `$schema` at all, and it works either way.
    """
    schema = dict(SEMANTIC_SCHEMA)
    schema.pop("$schema", None)
    return schema


def extract_semantic_json(raw: str) -> tuple[dict | None, str]:
    """Recover the candidate object from a `claude --output-format json` result string. With
    `--json-schema` passed to the CLI (investigate.py), `raw` should already be clean JSON --
    the fenced/brace-scan fallback exists because CLI output is never assumed compliant."""
    return extract_json(raw)


def validate_semantic(obj: dict | None) -> tuple[bool, list[str]]:
    """jsonschema-validate a candidate against `SEMANTIC_SCHEMA`. Errors are sorted by JSON
    path so the first difference is the first line, not an arbitrary one."""
    if not isinstance(obj, dict):
        return False, ["not a JSON object"]
    validator = jsonschema.Draft202012Validator(SEMANTIC_SCHEMA)
    errors = sorted(validator.iter_errors(obj), key=lambda e: list(e.path))
    return (len(errors) == 0), [f"{list(e.path)}: {e.message}" for e in errors]
