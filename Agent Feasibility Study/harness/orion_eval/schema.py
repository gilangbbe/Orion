"""The structured answer contract every model must return, plus a tolerant parser.

Structured-output reliability is one of the Task 3 axes, so we ask for JSON via the prompt
(no constrained decoding at baseline — that is a documented Task 3+ variant) and measure how
often the model actually produces valid, schema-conforming JSON.
"""
from __future__ import annotations

import json
import re
from typing import Any

EPISTEMIC_STATUSES = ["VERIFIED", "INFERRED", "UNKNOWN", "CONTRADICTED"]

# JSON Schema (draft 2020-12) for the model's answer object.
ANSWER_SCHEMA: dict[str, Any] = {
    "$schema": "https://json-schema.org/draft/2020-12/schema",
    "type": "object",
    "required": ["answer", "key_points", "evidence", "epistemic_status", "uncertainties"],
    "additionalProperties": True,
    "properties": {
        "answer": {"type": "string", "minLength": 1},
        "key_points": {"type": "array", "items": {"type": "string"}},
        "evidence": {
            "type": "array",
            "items": {
                "type": "object",
                "required": ["file", "why"],
                "properties": {
                    "file": {"type": "string"},
                    "symbol": {"type": ["string", "null"]},
                    "why": {"type": "string"},
                },
                "additionalProperties": True,
            },
        },
        "epistemic_status": {"type": "string", "enum": EPISTEMIC_STATUSES},
        "uncertainties": {"type": "array", "items": {"type": "string"}},
    },
}

SCHEMA_HINT = json.dumps(
    {
        "answer": "<your complete answer as prose>",
        "key_points": ["<claim 1>", "<claim 2>"],
        "evidence": [
            {"file": "starlette/<path>.py", "symbol": "Class.method or null", "why": "<what it shows>"}
        ],
        "epistemic_status": "one of VERIFIED | INFERRED | UNKNOWN | CONTRADICTED",
        "uncertainties": ["<what you could not establish from the provided material>"],
    },
    indent=2,
)

_FENCE_RE = re.compile(r"```(?:json)?\s*(.*?)\s*```", re.DOTALL | re.IGNORECASE)
_THINK_RE = re.compile(r"<think>.*?</think>", re.DOTALL | re.IGNORECASE)


def extract_json(raw: str) -> tuple[dict | None, str]:
    """Best-effort recovery of the JSON object from a raw completion.

    Returns (obj_or_None, method) where method describes how it was recovered
    ('clean', 'fenced', 'braces', 'none').
    """
    if not raw:
        return None, "none"
    text = _THINK_RE.sub("", raw).strip()

    try:
        return json.loads(text), "clean"
    except Exception:
        pass

    m = _FENCE_RE.search(text)
    if m:
        try:
            return json.loads(m.group(1)), "fenced"
        except Exception:
            pass

    start = text.find("{")
    end = text.rfind("}")
    if start != -1 and end != -1 and end > start:
        blob = text[start : end + 1]
        try:
            return json.loads(blob), "braces"
        except Exception:
            # last resort: trailing-comma cleanup
            cleaned = re.sub(r",(\s*[}\]])", r"\1", blob)
            try:
                return json.loads(cleaned), "braces"
            except Exception:
                pass
    return None, "none"


def validate_answer(obj: dict | None) -> tuple[bool, list[str]]:
    """Lightweight validation against ANSWER_SCHEMA. Avoids a hard jsonschema dependency
    at call sites; jsonschema is used by cli.resolve-anchors only."""
    errs: list[str] = []
    if not isinstance(obj, dict):
        return False, ["not a JSON object"]
    for key in ANSWER_SCHEMA["required"]:
        if key not in obj:
            errs.append(f"missing '{key}'")
    if "answer" in obj and not (isinstance(obj["answer"], str) and obj["answer"].strip()):
        errs.append("'answer' must be a non-empty string")
    if "key_points" in obj and not isinstance(obj["key_points"], list):
        errs.append("'key_points' must be an array")
    if "uncertainties" in obj and not isinstance(obj["uncertainties"], list):
        errs.append("'uncertainties' must be an array")
    if "evidence" in obj:
        if not isinstance(obj["evidence"], list):
            errs.append("'evidence' must be an array")
        else:
            for i, e in enumerate(obj["evidence"]):
                if not isinstance(e, dict) or "file" not in e:
                    errs.append(f"evidence[{i}] missing 'file'")
    if "epistemic_status" in obj and obj["epistemic_status"] not in EPISTEMIC_STATUSES:
        errs.append(f"epistemic_status not one of {EPISTEMIC_STATUSES}")
    return (len(errs) == 0), errs
