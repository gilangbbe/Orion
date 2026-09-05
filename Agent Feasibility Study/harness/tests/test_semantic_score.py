"""Docs/11 M5: the gold-set scorer's alignment/scoring math, against tiny synthetic data --
independent of any real Claude output (that's covered by the manual end-to-end run instead).

Run: cd 'Agent Feasibility Study/harness' && python -m unittest discover -s tests -t .
"""
from __future__ import annotations

import json
import unittest
from pathlib import Path
from tempfile import TemporaryDirectory

from orion_eval.semantic.score import (
    jaccard,
    normalize_anchor,
    score,
    score_components,
    score_evidence,
)


class NormalizeAnchorTests(unittest.TestCase):
    def test_strips_method_to_class(self):
        self.assertEqual(normalize_anchor("pkg/a.py::Widget.run"), "pkg/a.py::Widget")

    def test_strips_nested_closure_to_top_function(self):
        self.assertEqual(normalize_anchor("pkg/a.py::outer.inner.deepest"), "pkg/a.py::outer")

    def test_leaves_class_level_anchor_unchanged(self):
        self.assertEqual(normalize_anchor("pkg/a.py::Widget"), "pkg/a.py::Widget")

    def test_leaves_bare_module_path_unchanged(self):
        self.assertEqual(normalize_anchor("pkg/a.py"), "pkg/a.py")


class JaccardTests(unittest.TestCase):
    def test_identical_sets(self):
        self.assertEqual(jaccard({"a", "b"}, {"a", "b"}), 1.0)

    def test_disjoint_sets(self):
        self.assertEqual(jaccard({"a"}, {"b"}), 0.0)

    def test_partial_overlap(self):
        self.assertAlmostEqual(jaccard({"a", "b"}, {"b", "c"}), 1 / 3)

    def test_both_empty(self):
        self.assertEqual(jaccard(set(), set()), 1.0)


class ScoreComponentsTests(unittest.TestCase):
    def test_perfect_and_partial_and_spurious(self):
        gold = [
            {"name": "Routing", "member_anchors": ["r.py", "r.py::Router", "r.py::Route"]},
            {"name": "Responses", "member_anchors": ["resp.py", "resp.py::Response", "resp.py::JSONResponse"]},
        ]
        predicted = [
            # exact match for Routing
            {"name": "Routing & URLs", "member_anchors": ["r.py", "r.py::Router", "r.py::Route"]},
            # half-overlaps Responses (misses JSONResponse, has an extra)
            {"name": "Resp", "member_anchors": ["resp.py", "resp.py::Response", "resp.py::HTMLResponse"]},
            # shares nothing with any gold component
            {"name": "Ghost", "member_anchors": ["ghost.py", "ghost.py::Nothing"]},
        ]
        report = score_components(gold, predicted, threshold=0.3)

        self.assertEqual(len(report.matches), 2)
        by_gold = {m.gold_name: m for m in report.matches}

        routing = by_gold["Routing"]
        self.assertEqual(routing.predicted_name, "Routing & URLs")
        self.assertEqual(routing.jaccard, 1.0)
        self.assertEqual(routing.precision, 1.0)
        self.assertEqual(routing.recall, 1.0)
        self.assertEqual(routing.f1, 1.0)
        self.assertEqual(routing.gold_only, [])
        self.assertEqual(routing.predicted_only, [])

        responses = by_gold["Responses"]
        self.assertEqual(responses.predicted_name, "Resp")
        # intersection={resp.py, Response}=2, union=4 -> jaccard 0.5
        self.assertAlmostEqual(responses.jaccard, 0.5)
        self.assertAlmostEqual(responses.precision, 2 / 3)   # 2 of Resp's 3 anchors are right
        self.assertAlmostEqual(responses.recall, 2 / 3)      # 2 of gold's 3 anchors were found
        self.assertEqual(responses.gold_only, ["resp.py::JSONResponse"])
        self.assertEqual(responses.predicted_only, ["resp.py::HTMLResponse"])

        self.assertEqual(report.missed_gold, [])
        self.assertEqual(report.spurious_predicted, ["Ghost"])
        self.assertGreater(report.macro_f1, 0.0)
        self.assertLess(report.macro_f1, 1.0)

    def test_below_threshold_pair_counts_as_missed_and_spurious(self):
        gold = [{"name": "A", "member_anchors": ["x.py::X"]}]
        predicted = [{"name": "B", "member_anchors": ["y.py::Y"]}]
        report = score_components(gold, predicted, threshold=0.3)
        self.assertEqual(report.matches, [])
        self.assertEqual(report.missed_gold, ["A"])
        self.assertEqual(report.spurious_predicted, ["B"])

    def test_normalizes_before_comparing_so_method_level_prediction_still_matches(self):
        # gold is authored at class granularity; a real prediction routinely cites methods
        gold = [{"name": "Routing", "member_anchors": ["r.py::Router"]}]
        predicted = [{"name": "Routing", "member_anchors": ["r.py::Router.app", "r.py::Router.add_route"]}]
        report = score_components(gold, predicted, threshold=0.3)
        self.assertEqual(len(report.matches), 1)
        self.assertEqual(report.matches[0].jaccard, 1.0)  # both normalize to {r.py::Router}


class ScoreEvidenceTests(unittest.TestCase):
    def test_accuracy_excludes_unknown_and_counts_contradicted(self):
        claims = [
            {"claim_type": "INTERPRETATION"},
            {"claim_type": "INTERPRETATION"},
            {"claim_type": "CONTRADICTED"},
            {"claim_type": "UNKNOWN"},   # excluded -- never a checkable assertion
        ]
        evidenced, contradicted, accuracy = score_evidence(claims)
        self.assertEqual(evidenced, 3)
        self.assertEqual(contradicted, 1)
        self.assertAlmostEqual(accuracy, 2 / 3)

    def test_none_when_no_evidenced_claims(self):
        evidenced, contradicted, accuracy = score_evidence([{"claim_type": "UNKNOWN"}])
        self.assertEqual(evidenced, 0)
        self.assertIsNone(accuracy)


class ScoreEndToEndTests(unittest.TestCase):
    def test_reads_gold_and_export_files(self):
        with TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            gold_path = tmp_path / "gold.json"
            gold_path.write_text(json.dumps({
                "components": [{"name": "Routing", "member_anchors": ["r.py::Router"]}]
            }))

            export_dir = tmp_path / "export"
            export_dir.mkdir()
            (export_dir / "components.jsonl").write_text(
                json.dumps({"id": "c1", "name": "Routing", "member_anchors": ["r.py::Router.app"]}) + "\n"
            )
            (export_dir / "claims.jsonl").write_text(
                json.dumps({"claim_type": "INTERPRETATION"}) + "\n"
                + json.dumps({"claim_type": "CONTRADICTED"}) + "\n"
            )

            report = score(gold_path, export_dir)
            self.assertEqual(len(report.matches), 1)
            self.assertEqual(report.matches[0].jaccard, 1.0)
            self.assertEqual(report.evidenced_claim_count, 2)
            self.assertEqual(report.contradicted_claim_count, 1)
            self.assertAlmostEqual(report.evidence_accuracy, 0.5)


if __name__ == "__main__":
    unittest.main()
