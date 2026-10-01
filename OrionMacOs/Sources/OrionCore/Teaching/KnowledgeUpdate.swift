import Foundation

/// Docs/17_phase7_teaching_mode.md §8.2 — a Bayesian-Knowledge-Tracing-style update of a
/// developer's `p_mastered` for one concept, fed **criterion-level** (one observation per
/// confident `required` result, plus one strong-negative observation per tripped anti-criterion)
/// rather than one binary right/wrong per question. Pure math, no `Store` — `RubricGrader` (M4
/// wiring) and the tests call it directly.
///
/// **Decision 8 note (the "one look at real M2/M3 output")**: run against M3's own live grade
/// (2 `required` met → `.solid`; the "matches by specificity" answer → 2 `required` missed +
/// 1 anti), the §8.2 defaults give `p_mastered ≈ 0.81` for the good attempt and `≈ 0.15` for the
/// fully-wrong one. The wrong attempt lands back at the *prior*, not near 0, because the flat
/// `learn` term fills 15% of the gap regardless of correctness — a deliberate "engaging with the
/// concept still teaches you something" signal. The consequence, recorded rather than tuned away:
/// `p_mastered` alone cannot tell "never attempted" from "attempted and failed" — which is
/// exactly why `band(...)` gates on `attemptsCount` and why `TeachingPlanner` also weights an
/// open misconception. Priors kept at the §8.2 values.
public enum KnowledgeUpdate {

    public struct Params: Sendable, Equatable {
        public var prior: Double = 0.15
        public var slip: Double = 0.10       // P(answer wrong | mastered)
        public var guess: Double = 0.20      // P(answer right | not mastered)
        public var learn: Double = 0.15      // transit toward mastery from engaging with the concept
        public var antiSlip: Double = 0.05   // a tripped anti-criterion is stronger negative evidence
        public init() {}
    }

    /// Fold one binary observation into the posterior `p` (before the `learn` transit).
    public static func fold(p: Double, met: Bool, slip: Double, guess: Double) -> Double {
        let clamped = min(max(p, 1e-9), 1 - 1e-9)
        if met {
            let pObs = clamped * (1 - slip) + (1 - clamped) * guess
            return pObs > 0 ? (clamped * (1 - slip)) / pObs : clamped
        } else {
            let pObs = clamped * slip + (1 - clamped) * (1 - guess)
            return pObs > 0 ? (clamped * slip) / pObs : clamped
        }
    }

    /// Apply one whole graded attempt. `requiredMet` is the ordered list of confident `required`
    /// criterion outcomes (low-confidence ones are excluded upstream, matching `RubricScoring`);
    /// `antiTripped` is the count of confidently-met anti-criteria.
    public static func apply(
        prior: Double, requiredMet: [Bool], antiTripped: Int, params: Params = .init()
    ) -> Double {
        var p = prior
        for met in requiredMet {
            p = fold(p: p, met: met, slip: params.slip, guess: params.guess)
        }
        for _ in 0..<max(0, antiTripped) {
            p = fold(p: p, met: false, slip: params.antiSlip, guess: params.guess)
        }
        p = p + (1 - p) * params.learn
        return min(1.0, max(0.0, p))
    }

    /// `confidence_band` from the posterior + how many attempts back it (Docs/17 §8.1/§8.2).
    /// Stays `.new` until the second attempt regardless of `p` — one lucky question is not
    /// mastery (§2.5's small-N caution).
    public static func band(pMastered: Double, attemptsCount: Int) -> KnowledgeConfidenceBand {
        guard attemptsCount >= 2 else { return .new }
        if pMastered >= 0.85 { return .solid }
        if pMastered >= 0.55 { return .developing }
        return .shaky
    }
}
