import XCTest
import OrionCodeIntel
@testable import OrionAgent

/// Docs/17 M3: the local judge/comparer's prompt construction and tolerant parsing — no model.
final class CriterionJudgesTests: XCTestCase {

    func testParsesAWellFormedVerdict() async throws {
        let judge = LocalCriterionJudge { _ in
            """
            {"evidence_quote": "tried in order", "note": "explicit", "met": true, "confidence": "high"}
            """
        }
        let v = try await judge.judge(criterionText: "states dispatch order", criterionKind: .required,
                                      answer: "routes are tried in order", conceptEvidence: [])
        XCTAssertEqual(v, CriterionVerdict(met: true, confidence: .high,
                                          evidenceQuote: "tried in order", note: "explicit"))
    }

    func testUnparsableOutputBecomesLowConfidenceNotMet() async throws {
        let judge = LocalCriterionJudge { _ in "I think it's probably fine, honestly." }
        let v = try await judge.judge(criterionText: "x", criterionKind: .required, answer: "y",
                                      conceptEvidence: [])
        XCTAssertFalse(v.met)
        XCTAssertEqual(v.confidence, .low)
    }

    func testUnknownConfidenceStringFallsBackToLow() async throws {
        let judge = LocalCriterionJudge { _ in
            "{\"evidence_quote\": \"\", \"note\": \"\", \"met\": false, \"confidence\": \"pretty sure\"}"
        }
        let v = try await judge.judge(criterionText: "x", criterionKind: .bonus, answer: "y",
                                      conceptEvidence: [])
        XCTAssertEqual(v.confidence, .low)
    }

    func testAntiCriterionPromptFlagsTheInvertedMeaning() {
        let p = LocalCriterionJudge.buildPrompt(
            criterionText: "claims routes match by specificity", criterionKind: .anti,
            answer: "the answer", conceptEvidence: ["app/x.py::Router — class Router"])
        XCTAssertTrue(p.contains("ANTI-criterion"))
        XCTAssertTrue(p.contains("CONTAINS this WRONG idea"))
        XCTAssertTrue(p.contains("app/x.py::Router — class Router"))
    }

    func testComparerParsesSameFlag() async throws {
        let yes = LocalAnswerComparer { _ in "{\"same\": true}" }
        let no = LocalAnswerComparer { _ in "nonsense" }
        let a = try await yes.conveysSameIdea("x", as: "y")
        let b = try await no.conveysSameIdea("x", as: "y")
        XCTAssertTrue(a)
        XCTAssertFalse(b)   // unparsable -> conservative false
    }
}
