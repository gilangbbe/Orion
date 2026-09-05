"""Docs/11 M1: `ClaudeInvestigator` construction and result-parsing logic. No live `claude`
invocation here -- `run()`'s subprocess call is exercised manually (Docs/11 "Manual end-to-end").

Run: cd 'Agent Feasibility Study/harness' && python -m unittest discover -s tests -t .
"""
from __future__ import annotations

import json
import unittest
from pathlib import Path
from unittest import mock

from orion_eval.semantic.investigate import ClaudeInvestigator, READ_ONLY_TOOLS
from orion_eval.semantic.schema import SCHEMA_VERSION


class BuildPromptAndCommandTests(unittest.TestCase):
    def setUp(self):
        self.investigator = ClaudeInvestigator(
            repo_root=Path("/tmp/repo"), export_dir=Path("/tmp/repo-out/export"),
            claude_bin="claude",
        )

    def test_prompt_names_the_export_dir_and_schema_version(self):
        prompt = self.investigator.build_prompt()
        self.assertIn("/tmp/repo-out/export", prompt)
        self.assertIn(SCHEMA_VERSION, prompt)
        self.assertIn("anchor", prompt)

    def test_command_is_read_only_and_headless(self):
        cmd = self.investigator.build_command("<prompt>")
        self.assertIn("-p", cmd)
        self.assertIn("--output-format", cmd)
        self.assertEqual(cmd[cmd.index("--output-format") + 1], "json")
        self.assertIn("--tools", cmd)
        self.assertEqual(cmd[cmd.index("--tools") + 1], READ_ONLY_TOOLS)
        self.assertNotIn("Bash", READ_ONLY_TOOLS)
        self.assertNotIn("Edit", READ_ONLY_TOOLS)
        self.assertNotIn("Write", READ_ONLY_TOOLS)
        self.assertIn("--json-schema", cmd)
        # the CLI's own --json-schema validator rejects an explicit $schema dialect URI
        # (fails resolving the 2020-12 meta-schema offline) -- confirmed live 2026-09-04
        passed_schema = json.loads(cmd[cmd.index("--json-schema") + 1])
        self.assertNotIn("$schema", passed_schema)
        self.assertIn("--add-dir", cmd)
        # compare against the investigator's own (symlink-)resolved path, not a literal
        # re-construction -- macOS resolves /tmp -> /private/tmp
        self.assertEqual(cmd[cmd.index("--add-dir") + 1], str(self.investigator.export_dir))
        # prompt is the final positional -- no option can accidentally swallow it
        self.assertEqual(cmd[-1], "<prompt>")

    def test_command_pins_model_explicitly(self):
        investigator = ClaudeInvestigator(
            repo_root=Path("/tmp/repo"), export_dir=Path("/tmp/repo-out/export"),
            model="claude-sonnet-5", claude_bin="claude",
        )
        cmd = investigator.build_command("x")
        self.assertEqual(cmd[cmd.index("--model") + 1], "claude-sonnet-5")


class RunResultParsingTests(unittest.TestCase):
    """`run()`'s parsing of a `claude --output-format json` wrapper, with subprocess mocked."""

    def _investigator(self) -> ClaudeInvestigator:
        return ClaudeInvestigator(
            repo_root=Path("/tmp/repo"), export_dir=Path("/tmp/repo-out/export"),
            claude_bin="claude",
        )

    def _fake_proc(self, stdout: str, stderr: str = "", returncode: int = 0):
        return mock.Mock(stdout=stdout, stderr=stderr, returncode=returncode)

    def test_verified_outcome_for_valid_candidate(self):
        candidate = {
            "schema_version": SCHEMA_VERSION, "components": [], "component_relationships": [],
            "claims": [], "uncertainties": [],
        }
        wrapper = {
            "result": json.dumps(candidate), "session_id": "sess-1", "num_turns": 3,
            "total_cost_usd": 0.05, "duration_ms": 1200, "is_error": False, "model": "claude-sonnet-5",
        }
        with mock.patch("subprocess.run", return_value=self._fake_proc(json.dumps(wrapper))):
            result = self._investigator().run()
        self.assertEqual(result.outcome, "verified")
        self.assertTrue(result.ok)
        self.assertEqual(result.session_id, "sess-1")
        self.assertEqual(result.num_turns, 3)
        self.assertEqual(result.candidate["schema_version"], SCHEMA_VERSION)

    def test_prefers_structured_output_field_over_reparsing_result(self):
        # confirmed live 2026-09-04: with --json-schema, the wrapper's structured_output is
        # already the parsed candidate -- prefer it over re-extracting `result` text.
        candidate = {
            "schema_version": SCHEMA_VERSION, "components": [], "component_relationships": [],
            "claims": [], "uncertainties": [],
        }
        wrapper = {
            "result": "prose the model also said, not directly JSON-parseable as-is {oops",
            "structured_output": candidate, "is_error": False,
        }
        with mock.patch("subprocess.run", return_value=self._fake_proc(json.dumps(wrapper))):
            result = self._investigator().run()
        self.assertEqual(result.extraction_method, "structured_output")
        self.assertTrue(result.ok)

    def test_model_used_is_the_dominant_billed_model(self):
        # confirmed live 2026-09-04: the wrapper has no top-level "model" field, only a
        # per-model modelUsage breakdown (main investigation + small internal helper calls).
        candidate = {
            "schema_version": SCHEMA_VERSION, "components": [], "component_relationships": [],
            "claims": [], "uncertainties": [],
        }
        wrapper = {
            "structured_output": candidate, "is_error": False,
            "modelUsage": {
                "claude-haiku-4-5-20251001": {"costUSD": 0.0018},
                "claude-sonnet-5": {"costUSD": 1.38},
            },
        }
        with mock.patch("subprocess.run", return_value=self._fake_proc(json.dumps(wrapper))):
            result = self._investigator().run()
        self.assertEqual(result.model_used, "claude-sonnet-5")

    def test_model_used_falls_back_to_requested_model_without_usage(self):
        candidate = {
            "schema_version": SCHEMA_VERSION, "components": [], "component_relationships": [],
            "claims": [], "uncertainties": [],
        }
        wrapper = {"structured_output": candidate, "is_error": False}
        investigator = ClaudeInvestigator(
            repo_root=Path("/tmp/repo"), export_dir=Path("/tmp/repo-out/export"),
            model="claude-fable-5", claude_bin="claude",
        )
        with mock.patch("subprocess.run", return_value=self._fake_proc(json.dumps(wrapper))):
            result = investigator.run()
        self.assertEqual(result.model_used, "claude-fable-5")

    def test_unverified_outcome_when_candidate_fails_schema(self):
        wrapper = {
            "result": json.dumps({"schema_version": "wrong"}), "session_id": "sess-2",
            "is_error": False,
        }
        with mock.patch("subprocess.run", return_value=self._fake_proc(json.dumps(wrapper))):
            result = self._investigator().run()
        self.assertEqual(result.outcome, "unverified")
        self.assertFalse(result.ok)
        self.assertTrue(result.candidate_errors)

    def test_rejected_outcome_when_wrapper_reports_error(self):
        wrapper = {"result": "", "is_error": True, "session_id": "sess-3"}
        with mock.patch("subprocess.run", return_value=self._fake_proc(json.dumps(wrapper))):
            result = self._investigator().run()
        self.assertEqual(result.outcome, "rejected")
        self.assertFalse(result.ok)

    def test_rejected_outcome_when_stdout_is_not_json(self):
        with mock.patch("subprocess.run", return_value=self._fake_proc("not json")):
            result = self._investigator().run()
        self.assertEqual(result.outcome, "rejected")
        self.assertIsNone(result.candidate)

    def test_incomplete_outcome_on_timeout(self):
        import subprocess as sp
        with mock.patch("subprocess.run", side_effect=sp.TimeoutExpired(cmd="claude", timeout=1)):
            result = self._investigator().run()
        self.assertEqual(result.outcome, "incomplete")
        self.assertFalse(result.ok)


if __name__ == "__main__":
    unittest.main()
