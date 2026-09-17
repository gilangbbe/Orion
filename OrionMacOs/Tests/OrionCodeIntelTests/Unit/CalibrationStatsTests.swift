import XCTest
@testable import OrionCodeIntel

/// Docs/17 M7 / §12.2: the pure calibration statistics — Cohen's κ, score error, and the
/// verdict-tier confusion matrix — the grader-calibration gate is read off. No model, no `Store`.
final class CalibrationStatsTests: XCTestCase {

    // MARK: Cohen's κ

    func testKappaIsNilForEmptyInput() {
        XCTAssertNil(CalibrationStats.cohensKappa([(Bool, Bool)]()))
    }

    func testKappaIsOneForPerfectAgreementWithBothLabelsUsed() {
        let pairs: [(Bool, Bool)] = [(true, true), (false, false), (true, true), (false, false)]
        XCTAssertEqual(CalibrationStats.cohensKappa(pairs)!, 1.0, accuracy: 1e-9)
    }

    func testKappaIsOneByConventionWhenBothRatersOnlyEverSayMet() {
        // pₑ == 1 (0/0) -> convention: perfect-but-degenerate agreement reads as 1.0.
        let pairs: [(Bool, Bool)] = [(true, true), (true, true), (true, true)]
        XCTAssertEqual(CalibrationStats.cohensKappa(pairs)!, 1.0, accuracy: 1e-9)
    }

    func testKappaIsZeroForChanceLevelAgreement() {
        // Rater A: T,T,F,F ; Rater B: T,F,T,F. Observed agreement 0.5; each marginal 0.5/0.5 ->
        // expected agreement 0.5 -> κ == 0.
        let pairs: [(Bool, Bool)] = [(true, true), (true, false), (false, true), (false, false)]
        XCTAssertEqual(CalibrationStats.cohensKappa(pairs)!, 0.0, accuracy: 1e-9)
    }

    func testKappaIsNegativeWhenAgreementIsWorseThanChance() {
        let pairs: [(Bool, Bool)] = [(true, false), (false, true), (true, false), (false, true)]
        XCTAssertLessThan(CalibrationStats.cohensKappa(pairs)!, 0.0)
    }

    func testKappaKnownValue() {
        // 2x2: agree-met 20, agree-notmet 15, A-met/B-notmet 5, A-notmet/B-met 10. N=50.
        // pₒ = 35/50 = 0.70
        // marginA: met 25, notmet 25 ; marginB: met 30, notmet 20
        // pₑ = (25/50)(30/50) + (25/50)(20/50) = 0.30 + 0.20 = 0.50
        // κ = (0.70 - 0.50) / (1 - 0.50) = 0.40
        var pairs: [(String, String)] = []
        pairs += Array(repeating: ("met", "met"), count: 20)
        pairs += Array(repeating: ("notmet", "notmet"), count: 15)
        pairs += Array(repeating: ("met", "notmet"), count: 5)
        pairs += Array(repeating: ("notmet", "met"), count: 10)
        XCTAssertEqual(CalibrationStats.cohensKappa(pairs)!, 0.40, accuracy: 1e-9)
    }

    func testAgreementLabelBands() {
        XCTAssertEqual(CalibrationStats.agreementLabel(forKappa: -0.1), "poor (worse than chance)")
        XCTAssertEqual(CalibrationStats.agreementLabel(forKappa: 0.1), "slight")
        XCTAssertEqual(CalibrationStats.agreementLabel(forKappa: 0.3), "fair")
        XCTAssertEqual(CalibrationStats.agreementLabel(forKappa: 0.5), "moderate")
        XCTAssertEqual(CalibrationStats.agreementLabel(forKappa: 0.7), "substantial")
        XCTAssertEqual(CalibrationStats.agreementLabel(forKappa: 0.9), "almost perfect")
    }

    // MARK: error

    func testMeanAbsoluteError() {
        XCTAssertNil(CalibrationStats.meanAbsoluteError([]))
        let pairs: [(Double, Double)] = [(1.0, 1.0), (0.0, 0.5), (0.8, 0.6)]
        // |0| + |0.5| + |0.2| = 0.7 ; /3
        XCTAssertEqual(CalibrationStats.meanAbsoluteError(pairs)!, 0.7 / 3.0, accuracy: 1e-9)
    }

    func testRootMeanSquareErrorPunishesLargeMisses() {
        let small: [(Double, Double)] = [(0.5, 0.6), (0.5, 0.4), (0.5, 0.6), (0.5, 0.4)]
        let oneBig: [(Double, Double)] = [(0.5, 0.5), (0.5, 0.5), (0.5, 0.5), (0.5, 0.9)]
        XCTAssertEqual(CalibrationStats.meanAbsoluteError(small)!, 0.1, accuracy: 1e-9)
        XCTAssertEqual(CalibrationStats.meanAbsoluteError(oneBig)!, 0.1, accuracy: 1e-9)
        // Same MAE, but the single 0.4 miss makes RMSE larger.
        XCTAssertGreaterThan(
            CalibrationStats.rootMeanSquareError(oneBig)!,
            CalibrationStats.rootMeanSquareError(small)!)
    }

    // MARK: confusion matrix

    func testConfusionMatrixCountsAndAccuracy() {
        let pairs: [(expected: String, actual: String)] = [
            ("solid", "solid"), ("solid", "partial"), ("partial", "partial"),
            ("shaky", "shaky"), ("shaky", "off-track"), ("off-track", "off-track"),
        ]
        let m = CalibrationStats.confusionMatrix(
            pairs, categories: ["solid", "partial", "shaky", "off-track"])
        XCTAssertEqual(m.count(expected: "solid", actual: "solid"), 1)
        XCTAssertEqual(m.count(expected: "solid", actual: "partial"), 1)
        XCTAssertEqual(m.count(expected: "shaky", actual: "off-track"), 1)
        XCTAssertEqual(m.total, 6)
        XCTAssertEqual(m.accuracy!, 4.0 / 6.0, accuracy: 1e-9)
    }

    func testConfusionMatrixIgnoresUnknownCategories() {
        let pairs: [(expected: String, actual: String)] = [
            ("met", "met"), ("ambiguous", "met"), ("met", "notmet"),
        ]
        let m = CalibrationStats.confusionMatrix(pairs, categories: ["met", "notmet"])
        XCTAssertEqual(m.total, 2)   // the ("ambiguous", "met") pair is dropped
        XCTAssertEqual(m.count(expected: "met", actual: "met"), 1)
        XCTAssertEqual(m.count(expected: "met", actual: "notmet"), 1)
    }

    func testConfusionMatrixAccuracyIsNilWhenEmpty() {
        let m = CalibrationStats.confusionMatrix([(expected: "a", actual: "b")], categories: ["x", "y"])
        XCTAssertNil(m.accuracy)
    }
}
