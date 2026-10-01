import XCTest
@testable import OrionCodeIntel
@testable import OrionCore

/// Docs/17 M4: the §8.2 BKT-style mastery update, in isolation. Numbers hand-checked against the
/// pseudocode with the §8.2 default params (slip 0.1, guess 0.2, learn 0.15, antiSlip 0.05).
final class KnowledgeUpdateTests: XCTestCase {

    private let p = KnowledgeUpdate.Params()

    func testFoldOnAMetObservationRaisesP() {
        // p_obs = 0.15*0.9 + 0.85*0.2 = 0.305 ; posterior = 0.135/0.305 = 0.442623
        let out = KnowledgeUpdate.fold(p: 0.15, met: true, slip: p.slip, guess: p.guess)
        XCTAssertEqual(out, 0.135 / 0.305, accuracy: 1e-6)
        XCTAssertGreaterThan(out, 0.15)
    }

    func testFoldOnANotMetObservationLowersP() {
        // p_obs = 0.15*0.1 + 0.85*0.8 = 0.695 ; posterior = 0.015/0.695 = 0.021583
        let out = KnowledgeUpdate.fold(p: 0.15, met: false, slip: p.slip, guess: p.guess)
        XCTAssertEqual(out, 0.015 / 0.695, accuracy: 1e-6)
        XCTAssertLessThan(out, 0.15)
    }

    func testTwoMetRequiredFromPriorLandsAroundZeroEightOne() {
        // Docs/17 §8.2 "one look": the good M3 attempt (2 required met).
        let out = KnowledgeUpdate.apply(prior: 0.15, requiredMet: [true, true], antiTripped: 0, params: p)
        XCTAssertEqual(out, 0.814, accuracy: 0.01)
    }

    func testFullyWrongAttemptLandsBackAtThePrior() {
        // The recorded finding: 2 required missed + 1 anti -> p ≈ 0, but the flat `learn` term
        // fills 15% of the gap, so it lands ≈ 0.15 (the prior), not near zero.
        let out = KnowledgeUpdate.apply(prior: 0.15, requiredMet: [false, false], antiTripped: 1, params: p)
        XCTAssertEqual(out, 0.15, accuracy: 0.02)
    }

    func testNoConfidentRequiredIsLearnOnly() {
        // Every required criterion came back low-confidence -> excluded; only the `learn` transit
        // applies: 0.15 + 0.85*0.15 = 0.2775.
        let out = KnowledgeUpdate.apply(prior: 0.15, requiredMet: [], antiTripped: 0, params: p)
        XCTAssertEqual(out, 0.2775, accuracy: 1e-6)
    }

    func testRepeatedMetAttemptsConvergeUpward() {
        var pm = 0.15
        var last = pm
        for _ in 0..<5 {
            pm = KnowledgeUpdate.apply(prior: pm, requiredMet: [true, true], antiTripped: 0, params: p)
            XCTAssertGreaterThan(pm, last)
            last = pm
        }
        XCTAssertGreaterThan(pm, 0.95)
    }

    func testBandStaysNewUntilTwoAttempts() {
        XCTAssertEqual(KnowledgeUpdate.band(pMastered: 0.99, attemptsCount: 0), .new)
        XCTAssertEqual(KnowledgeUpdate.band(pMastered: 0.99, attemptsCount: 1), .new)
        XCTAssertEqual(KnowledgeUpdate.band(pMastered: 0.99, attemptsCount: 2), .solid)
    }

    func testBandCutoffs() {
        XCTAssertEqual(KnowledgeUpdate.band(pMastered: 0.90, attemptsCount: 3), .solid)
        XCTAssertEqual(KnowledgeUpdate.band(pMastered: 0.70, attemptsCount: 3), .developing)
        XCTAssertEqual(KnowledgeUpdate.band(pMastered: 0.55, attemptsCount: 3), .developing)
        XCTAssertEqual(KnowledgeUpdate.band(pMastered: 0.40, attemptsCount: 3), .shaky)
        XCTAssertEqual(KnowledgeUpdate.band(pMastered: 0.10, attemptsCount: 3), .shaky)
    }

    func testResultIsClampedToUnitInterval() {
        let hi = KnowledgeUpdate.apply(prior: 0.999999, requiredMet: [true, true, true], antiTripped: 0, params: p)
        XCTAssertLessThanOrEqual(hi, 1.0)
        let lo = KnowledgeUpdate.apply(prior: 1e-9, requiredMet: [false, false], antiTripped: 3, params: p)
        XCTAssertGreaterThanOrEqual(lo, 0.0)
    }
}
