import XCTest
@testable import OrionCodeIntel

/// Docs/16 M1: `AnchorAlignment` ported from Phase 2 M5's `score.py`
/// (`Agent Feasibility Study/harness/orion_eval/semantic/score.py`) — these cases are ported
/// directly from that file's own `test_semantic_score.py` fixtures, so this port is checked
/// against known-correct numbers rather than newly invented ones.
final class AnchorAlignmentTests: XCTestCase {

    // MARK: normalize(_:) -- ported from NormalizeAnchorTests

    func testNormalizeStripsMethodToClass() {
        XCTAssertEqual(AnchorAlignment.normalize("pkg/a.py::Widget.run"), "pkg/a.py::Widget")
    }

    func testNormalizeStripsNestedClosureToTopFunction() {
        XCTAssertEqual(AnchorAlignment.normalize("pkg/a.py::outer.inner.deepest"), "pkg/a.py::outer")
    }

    func testNormalizeLeavesClassLevelAnchorUnchanged() {
        XCTAssertEqual(AnchorAlignment.normalize("pkg/a.py::Widget"), "pkg/a.py::Widget")
    }

    func testNormalizeLeavesBareModulePathUnchanged() {
        XCTAssertEqual(AnchorAlignment.normalize("pkg/a.py"), "pkg/a.py")
    }

    // MARK: jaccard(_:_:) -- ported from JaccardTests

    func testJaccardIdenticalSets() {
        XCTAssertEqual(AnchorAlignment.jaccard(["a", "b"], ["a", "b"]), 1.0)
    }

    func testJaccardDisjointSets() {
        XCTAssertEqual(AnchorAlignment.jaccard(["a"], ["b"]), 0.0)
    }

    func testJaccardPartialOverlap() {
        XCTAssertEqual(AnchorAlignment.jaccard(["a", "b"], ["b", "c"]), 1.0 / 3.0, accuracy: 1e-9)
    }

    func testJaccardBothEmpty() {
        XCTAssertEqual(AnchorAlignment.jaccard([], []), 1.0)
    }

    // MARK: align(lhs:rhs:threshold:) -- ported from ScoreComponentsTests

    func testPerfectPartialAndSpuriousAlignment() {
        // lhs = gold, rhs = predicted, matching score.py's own test_perfect_and_partial_and_spurious.
        let gold: [(id: String, anchors: Set<String>)] = [
            (id: "Routing", anchors: ["r.py", "r.py::Router", "r.py::Route"]),
            (id: "Responses", anchors: ["resp.py", "resp.py::Response", "resp.py::JSONResponse"])
        ]
        let predicted: [(id: String, anchors: Set<String>)] = [
            // exact match for Routing
            (id: "Routing & URLs", anchors: ["r.py", "r.py::Router", "r.py::Route"]),
            // half-overlaps Responses (misses JSONResponse, has an extra)
            (id: "Resp", anchors: ["resp.py", "resp.py::Response", "resp.py::HTMLResponse"]),
            // shares nothing with any gold component
            (id: "Ghost", anchors: ["ghost.py", "ghost.py::Nothing"])
        ]

        let result = AnchorAlignment.align(lhs: gold, rhs: predicted, threshold: 0.3)
        XCTAssertEqual(result.matches.count, 2)
        let byLhs = Dictionary(uniqueKeysWithValues: result.matches.map { ($0.lhsId, $0) })

        let routing = try! XCTUnwrap(byLhs["Routing"])
        XCTAssertEqual(routing.rhsId, "Routing & URLs")
        XCTAssertEqual(routing.jaccard, 1.0)
        XCTAssertEqual(routing.precision, 1.0)
        XCTAssertEqual(routing.recall, 1.0)
        XCTAssertEqual(routing.f1, 1.0)
        XCTAssertEqual(routing.lhsOnly, [])
        XCTAssertEqual(routing.rhsOnly, [])

        let responses = try! XCTUnwrap(byLhs["Responses"])
        XCTAssertEqual(responses.rhsId, "Resp")
        // intersection={resp.py, Response}=2, union=4 -> jaccard 0.5
        XCTAssertEqual(responses.jaccard, 0.5, accuracy: 1e-9)
        XCTAssertEqual(responses.precision, 2.0 / 3.0, accuracy: 1e-9)   // 2 of Resp's 3 anchors are right
        XCTAssertEqual(responses.recall, 2.0 / 3.0, accuracy: 1e-9)      // 2 of gold's 3 anchors were found
        XCTAssertEqual(responses.lhsOnly, ["resp.py::JSONResponse"])
        XCTAssertEqual(responses.rhsOnly, ["resp.py::HTMLResponse"])

        XCTAssertEqual(result.unmatchedLhs, [])
        XCTAssertEqual(result.unmatchedRhs, ["Ghost"])
    }

    func testBelowThresholdPairCountsAsUnmatchedOnBothSides() {
        let lhs: [(id: String, anchors: Set<String>)] = [(id: "A", anchors: ["x.py::X"])]
        let rhs: [(id: String, anchors: Set<String>)] = [(id: "B", anchors: ["y.py::Y"])]
        let result = AnchorAlignment.align(lhs: lhs, rhs: rhs, threshold: 0.3)
        XCTAssertTrue(result.matches.isEmpty)
        XCTAssertEqual(result.unmatchedLhs, ["A"])
        XCTAssertEqual(result.unmatchedRhs, ["B"])
    }

    func testNormalizesBeforeComparingSoMethodLevelPredictionStillMatches() {
        // gold is authored at class granularity; a real prediction routinely cites methods.
        let lhs: [(id: String, anchors: Set<String>)] = [(id: "Routing", anchors: ["r.py::Router"])]
        let rhs: [(id: String, anchors: Set<String>)] = [
            (id: "Routing", anchors: ["r.py::Router.app", "r.py::Router.add_route"])
        ]
        let result = AnchorAlignment.align(lhs: lhs, rhs: rhs, threshold: 0.3)
        XCTAssertEqual(result.matches.count, 1)
        XCTAssertEqual(result.matches[0].jaccard, 1.0)  // both normalize to {r.py::Router}
    }

    func testDefaultThresholdMatchesScorePyConstant() {
        XCTAssertEqual(AnchorAlignment.defaultThreshold, 0.3)
    }
}
