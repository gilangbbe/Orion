"""Docs/11 M1: the Python-side (step 1) half of the structured-output contract.

Run: cd 'Agent Feasibility Study/harness' && python -m unittest discover -s tests -t .
"""
from __future__ import annotations

import unittest

import jsonschema

from orion_eval.semantic.schema import (
    SCHEMA_VERSION,
    SEMANTIC_SCHEMA,
    cli_json_schema,
    extract_semantic_json,
    validate_semantic,
)

VALID = {
    "schema_version": SCHEMA_VERSION,
    "components": [{
        "name": "Widgets",
        "description": "Widget stuff.",
        "architectural_role": "core",
        "members": ["pkg/core.py::Widget"],
    }],
    "component_relationships": [],
    "claims": [{
        "claim_type": "INTERPRETATION",
        "statement": "Widget.run returns a constant.",
        "evidence": ["pkg/core.py::Widget.run"],
        "confidence": "high",
    }],
    "uncertainties": ["Whether Widget.run always returns 1."],
}


class ValidateSemanticTests(unittest.TestCase):
    def test_accepts_well_formed_candidate(self):
        ok, errors = validate_semantic(VALID)
        self.assertTrue(ok, errors)
        self.assertEqual(errors, [])

    def test_rejects_wrong_schema_version(self):
        bad = {**VALID, "schema_version": "phase1.v9"}
        ok, errors = validate_semantic(bad)
        self.assertFalse(ok)
        self.assertTrue(any("schema_version" in e for e in errors))

    def test_rejects_component_with_no_members(self):
        bad = {**VALID, "components": [{"name": "Ghosts", "members": []}]}
        ok, errors = validate_semantic(bad)
        self.assertFalse(ok)

    def test_rejects_fact_claim_type(self):
        # Claude may never self-tag FACT -- that tier is reserved for Phase 1 output.
        claim = dict(VALID["claims"][0])
        claim["claim_type"] = "FACT"
        bad = {**VALID, "claims": [claim]}
        ok, errors = validate_semantic(bad)
        self.assertFalse(ok)

    def test_rejects_contradicted_claim_type(self):
        # CONTRADICTED is a Swift-side verdict, never something Claude asserts itself.
        claim = dict(VALID["claims"][0])
        claim["claim_type"] = "CONTRADICTED"
        bad = {**VALID, "claims": [claim]}
        ok, _ = validate_semantic(bad)
        self.assertFalse(ok)

    def test_rejects_unknown_top_level_key(self):
        bad = {**VALID, "extra_field": "not allowed"}
        ok, _ = validate_semantic(bad)
        self.assertFalse(ok)

    def test_rejects_non_object(self):
        ok, errors = validate_semantic(None)
        self.assertFalse(ok)
        self.assertEqual(errors, ["not a JSON object"])


class CliJsonSchemaTests(unittest.TestCase):
    """The `claude --json-schema` flag's own validator rejects an explicit 2020-12 `$schema`
    (it fails to resolve the meta-schema offline) -- confirmed against a live run 2026-09-04.
    `cli_json_schema()` strips it; everything else must stay identical."""

    def test_strips_schema_dialect_key(self):
        cli_schema = cli_json_schema()
        self.assertNotIn("$schema", cli_schema)
        self.assertIn("$schema", SEMANTIC_SCHEMA)  # the source is untouched

    def test_still_validates_the_same_documents(self):
        validator = jsonschema.Draft202012Validator(cli_json_schema())
        self.assertEqual(list(validator.iter_errors(VALID)), [])
        bad = {**VALID, "schema_version": "wrong"}
        self.assertTrue(list(validator.iter_errors(bad)))


class ExtractSemanticJsonTests(unittest.TestCase):
    def test_recovers_clean_json(self):
        import json
        obj, method = extract_semantic_json(json.dumps(VALID))
        self.assertEqual(method, "clean")
        self.assertEqual(obj["schema_version"], SCHEMA_VERSION)

    def test_recovers_fenced_json(self):
        import json
        raw = f"Here you go:\n```json\n{json.dumps(VALID)}\n```\n"
        obj, method = extract_semantic_json(raw)
        self.assertEqual(method, "fenced")
        self.assertEqual(obj["schema_version"], SCHEMA_VERSION)

    def test_returns_none_on_garbage(self):
        obj, method = extract_semantic_json("not json at all")
        self.assertIsNone(obj)
        self.assertEqual(method, "none")


if __name__ == "__main__":
    unittest.main()
