import XCTest
@testable import OrionCodeIntel

/// Docs/17 M3: the deterministic §7.3 threshold math, in isolation from any model or `Store`.
final class RubricScoringTests: XCTestCase {

    private func row(_ kind: RubricCriterionKind, met: Bool, confident: Bool = true, _ text: String = "c")
        -> RubricScoring.AggregateInput.Row
    {
        .init(kind: kind, met: met, confident: confident, text: text)
    }

    private func agg(_ rows: [RubricScoring.AggregateInput.Row]) -> RubricScoring.Aggregate {
        RubricScoring.aggregate(RubricScoring.AggregateInput(rows: rows))
    }

    func testAllRequiredMetIsSolid() {
        let a = agg([row(.required, met: true), row(.required, met: true), row(.required, met: true)])
        XCTAssertEqual(a.score, 1.0, accuracy: 1e-9)
        XCTAssertEqual(a.verdict, .solid)
        XCTAssertEqual([a.requiredMet, a.requiredTotal], [3, 3])
    }

    func testTwoOfThreeRequiredIsPartial() {
        let a = agg([row(.required, met: true), row(.required, met: true), row(.required, met: false)])
        XCTAssertEqual(a.score, 2.0 / 3.0, accuracy: 1e-9)
        XCTAssertEqual(a.verdict, .partial)
    }

    func testOneOfThreeRequiredIsShaky() {
        let a = agg([row(.required, met: true), row(.required, met: false), row(.required, met: false)])
        XCTAssertEqual(a.verdict, .shaky)
    }

    func testAntiTrippedWithTwoRequiredMissedForcesOffTrack() {
        let a = agg([
            row(.required, met: true), row(.required, met: false), row(.required, met: false),
            row(.anti, met: true),
        ])
        XCTAssertEqual(a.antiTripped, 1)
        XCTAssertEqual(a.verdict, .offTrack)
    }

    func testAntiTrippedWithOnlyOneRequiredMissedIsNotForcedOffTrack() {
        let a = agg([
            row(.required, met: true), row(.required, met: true), row(.required, met: false),
            row(.anti, met: true),
        ])
        XCTAssertEqual(a.verdict, .partial)   // score 0.667, one miss -> not the 2-miss off-track bar
    }

    func testLowConfidenceRequiredExcludedFromDenominator() {
        let a = agg([
            row(.required, met: true), row(.required, met: true),
            row(.required, met: false, confident: false, "unsure one"),
        ])
        XCTAssertEqual([a.requiredMet, a.requiredTotal], [2, 2])
        XCTAssertEqual(a.score, 1.0, accuracy: 1e-9)
        XCTAssertEqual(a.needsReview, ["unsure one"])
    }

    func testBonusAddsACappedMargin() {
        let rows = [row(.required, met: true), row(.required, met: false)]
            + Array(repeating: row(.bonus, met: true), count: 4)
        let a = agg(rows)
        XCTAssertEqual(a.bonusMet, 4)
        XCTAssertEqual(a.score, 0.5 + 0.15, accuracy: 1e-9)   // capped at +0.15, not 4*0.05=0.20
        XCTAssertEqual(a.verdict, .partial)
    }

    func testAllRequiredLowConfidenceIsShakyWithZeroScore() {
        let a = agg([
            row(.required, met: true, confident: false, "a"),
            row(.required, met: true, confident: false, "b"),
        ])
        XCTAssertEqual(a.score, 0.0, accuracy: 1e-9)
        XCTAssertEqual(a.verdict, .shaky)
        XCTAssertEqual(a.needsReview.count, 2)
    }

    func testCorrectionTextListsUnmetAndTrippedAnti() {
        let text = RubricScoring.correctionText(
            unmetRequired: ["states dispatch order"], trippedAnti: ["claims longest-prefix match"],
            needsReview: [], referenceAnswer: "Routes are tried in order.")
        XCTAssertTrue(text.contains("didn't establish"))
        XCTAssertTrue(text.contains("states dispatch order"))
        XCTAssertTrue(text.contains("implied"))
        XCTAssertTrue(text.contains("longest-prefix"))
        XCTAssertTrue(text.contains("Reference: Routes are tried in order."))
    }

    func testCorrectionTextWhenEverythingCovered() {
        let text = RubricScoring.correctionText(
            unmetRequired: [], trippedAnti: [], needsReview: [], referenceAnswer: "ref")
        XCTAssertTrue(text.contains("covered every required point"))
    }
}
