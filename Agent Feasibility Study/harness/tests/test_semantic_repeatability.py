"""Docs/11 M6: repeatability report machinery, against synthetic multi-run fixtures -- no live
`claude` call needed to verify the comparison logic itself (that's the manual part, run by
hand, one investigation at a time).

Run: cd 'Agent Feasibility Study/harness' && python -m unittest discover -s tests -t .
"""
from __future__ import annotations

import json
import unittest
from pathlib import Path
from tempfile import TemporaryDirectory

from orion_eval.cli import _next_repeatability_dir
from orion_eval.semantic.repeatability import (
    build_report,
    discover_failed_runs,
    discover_runs,
    pairwise_stability,
    summarize_run,
)


def _write_run(base: Path, label: str, components: list[dict], meta: dict) -> Path:
    run_dir = base / "repeatability" / label
    run_dir.mkdir(parents=True)
    (run_dir / "semantic_findings.json").write_text(json.dumps({
        "schema_version": "phase2.v1",
        "components": components,
        "component_relationships": [],
        "claims": [{"claim_type": "INTERPRETATION", "statement": "x", "evidence": ["a"], "confidence": "high"}],
        "uncertainties": ["u1"],
    }))
    (run_dir / "investigation_meta.json").write_text(json.dumps(meta))
    return run_dir


class NextRepeatabilityDirTests(unittest.TestCase):
    def test_first_call_creates_run1(self):
        with TemporaryDirectory() as tmp:
            out_dir = Path(tmp)
            run_dir, n = _next_repeatability_dir(out_dir)
            self.assertEqual(n, 1)
            self.assertEqual(run_dir.name, "run1")
            self.assertTrue(run_dir.is_dir())

    def test_second_call_creates_run2_without_touching_run1(self):
        with TemporaryDirectory() as tmp:
            out_dir = Path(tmp)
            run1, _ = _next_repeatability_dir(out_dir)
            (run1 / "marker.txt").write_text("keep me")
            run2, n = _next_repeatability_dir(out_dir)
            self.assertEqual(n, 2)
            self.assertEqual(run2.name, "run2")
            self.assertTrue((run1 / "marker.txt").is_file())  # untouched

    def test_picks_up_after_existing_runs_on_disk(self):
        # simulates re-invoking the CLI in a fresh process after two prior runs
        with TemporaryDirectory() as tmp:
            out_dir = Path(tmp)
            (out_dir / "repeatability" / "run1").mkdir(parents=True)
            (out_dir / "repeatability" / "run2").mkdir(parents=True)
            _, n = _next_repeatability_dir(out_dir)
            self.assertEqual(n, 3)


class DiscoverRunsTests(unittest.TestCase):
    def test_finds_and_numerically_sorts_runs(self):
        with TemporaryDirectory() as tmp:
            out_dir = Path(tmp)
            for label in ["run2", "run10", "run1"]:
                _write_run(out_dir, label, [{"name": "A", "members": ["x.py"]}], {})
            found = discover_runs(out_dir)
            self.assertEqual([d.name for d in found], ["run1", "run2", "run10"])  # not alpha order

    def test_skips_run_dirs_without_a_candidate(self):
        with TemporaryDirectory() as tmp:
            out_dir = Path(tmp)
            (out_dir / "repeatability" / "run1").mkdir(parents=True)  # empty, no candidate
            self.assertEqual(discover_runs(out_dir), [])

    def test_empty_when_no_repeatability_dir(self):
        with TemporaryDirectory() as tmp:
            self.assertEqual(discover_runs(Path(tmp)), [])


class DiscoverFailedRunsTests(unittest.TestCase):
    def test_finds_run_with_no_candidate_and_explains_api_overload(self):
        # the actual shape hit in practice: Anthropic's API returned 529 Overloaded before
        # Claude produced any answer, so `investigate` wrote a raw wrapper + meta but no
        # semantic_findings.json.
        with TemporaryDirectory() as tmp:
            out_dir = Path(tmp)
            run_dir = out_dir / "repeatability" / "run2"
            run_dir.mkdir(parents=True)
            (run_dir / "semantic_findings.raw.json").write_text(json.dumps({
                "is_error": True, "terminal_reason": "api_error", "api_error_status": 529,
                "result": "API Error: 529 Overloaded. This is a server-side issue, usually temporary.",
            }))
            (run_dir / "investigation_meta.json").write_text("{}")

            failed = discover_failed_runs(out_dir)
            self.assertEqual(len(failed), 1)
            path, reason = failed[0]
            self.assertEqual(path.name, "run2")
            self.assertIn("api_error", reason)
            self.assertIn("529", reason)

    def test_successful_run_is_not_reported_as_failed(self):
        with TemporaryDirectory() as tmp:
            out_dir = Path(tmp)
            _write_run(out_dir, "run1", [{"name": "A", "members": ["x.py"]}], {})
            self.assertEqual(discover_failed_runs(out_dir), [])

    def test_empty_when_no_repeatability_dir(self):
        with TemporaryDirectory() as tmp:
            self.assertEqual(discover_failed_runs(Path(tmp)), [])


class SummarizeRunTests(unittest.TestCase):
    def test_reads_counts_and_meta(self):
        with TemporaryDirectory() as tmp:
            out_dir = Path(tmp)
            run_dir = _write_run(
                out_dir, "run1",
                [{"name": "A", "members": ["x.py"]}, {"name": "B", "members": ["y.py"]}],
                {"model_used": "claude-sonnet-5", "num_turns": 10, "total_cost_usd": 1.5, "duration_ms": 2000},
            )
            s = summarize_run(run_dir)
            self.assertEqual(s.component_count, 2)
            self.assertEqual(s.evidenced_claim_count, 1)
            self.assertEqual(s.uncertainty_count, 1)
            self.assertEqual(s.num_turns, 10)
            self.assertEqual(s.total_cost_usd, 1.5)


class PairwiseStabilityTests(unittest.TestCase):
    def test_identical_runs_score_1(self):
        with TemporaryDirectory() as tmp:
            out_dir = Path(tmp)
            comps = [{"name": "Routing", "members": ["r.py::Router", "r.py::Route"]}]
            a = _write_run(out_dir, "run1", comps, {})
            b = _write_run(out_dir, "run2", comps, {})
            p = pairwise_stability(a, b)
            self.assertEqual(p.macro_f1, 1.0)
            self.assertEqual(p.matched, 1)
            self.assertEqual(p.missed, 0)
            self.assertEqual(p.spurious, 0)

    def test_completely_different_runs_score_low(self):
        with TemporaryDirectory() as tmp:
            out_dir = Path(tmp)
            a = _write_run(out_dir, "run1", [{"name": "A", "members": ["x.py::X"]}], {})
            b = _write_run(out_dir, "run2", [{"name": "Z", "members": ["z.py::Z"]}], {})
            p = pairwise_stability(a, b)
            self.assertEqual(p.matched, 0)
            self.assertEqual(p.missed, 1)
            self.assertEqual(p.spurious, 1)
            self.assertEqual(p.macro_f1, 0.0)

    def test_component_names_differing_but_same_members_still_match(self):
        # this is the point of the whole exercise -- two runs naming the same real grouping
        # differently ("Routing" vs "Routing & URL Convertors") should still count as stable
        with TemporaryDirectory() as tmp:
            out_dir = Path(tmp)
            a = _write_run(out_dir, "run1", [{"name": "Routing", "members": ["r.py::Router"]}], {})
            b = _write_run(out_dir, "run2", [{"name": "Routing & URLs", "members": ["r.py::Router"]}], {})
            p = pairwise_stability(a, b)
            self.assertEqual(p.macro_f1, 1.0)


class BuildReportTests(unittest.TestCase):
    def test_three_runs_produce_three_pairs_and_stats(self):
        with TemporaryDirectory() as tmp:
            out_dir = Path(tmp)
            comps = [{"name": "A", "members": ["x.py::X"]}]
            _write_run(out_dir, "run1", comps, {"total_cost_usd": 1.0, "num_turns": 10, "duration_ms": 1000})
            _write_run(out_dir, "run2", comps, {"total_cost_usd": 2.0, "num_turns": 20, "duration_ms": 2000})
            _write_run(out_dir, "run3", comps, {"total_cost_usd": 3.0, "num_turns": 30, "duration_ms": 3000})

            report = build_report(out_dir)
            self.assertEqual(len(report.runs), 3)
            self.assertEqual(len(report.pairs), 3)  # C(3,2)
            self.assertEqual(report.mean_pairwise_f1, 1.0)  # identical components every run
            self.assertEqual(report.cost_usd, {"min": 1.0, "max": 3.0, "mean": 2.0})
            self.assertEqual(report.num_turns, {"min": 10, "max": 30, "mean": 20})

    def test_single_run_has_no_pairs(self):
        with TemporaryDirectory() as tmp:
            out_dir = Path(tmp)
            _write_run(out_dir, "run1", [{"name": "A", "members": ["x.py"]}], {})
            report = build_report(out_dir)
            self.assertEqual(len(report.runs), 1)
            self.assertEqual(report.pairs, [])
            self.assertIsNone(report.mean_pairwise_f1)

    def test_no_runs_at_all(self):
        with TemporaryDirectory() as tmp:
            report = build_report(Path(tmp))
            self.assertEqual(report.runs, [])
            self.assertEqual(report.pairs, [])


if __name__ == "__main__":
    unittest.main()
