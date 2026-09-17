import Foundation

/// Docs/17_phase7_teaching_mode.md §12.2 — the deterministic statistics the grader-calibration
/// gate is measured with: inter-rater agreement (Cohen's κ) between the LLM grader's per-criterion
/// `met` verdicts and expert labels, the error of the *derived* score against the expert-derived
/// score, and a verdict-tier confusion matrix. Pure functions over already-paired observations —
/// no model, no `Store`, no I/O — so the whole gate is unit-testable in isolation and the
/// `orion-agent teach bench` command (§10) is only orchestration on top of these, exactly as
/// `BenchSummary` sits on top of `orion-agent bench`'s per-question rows (Phase 5 M7).
///
/// This is the concrete form of Phase 7's thesis (Docs/17 §2.1): the LLM emits atomic booleans,
/// and *code* — here — turns a set of them into a measurable, reportable number.
public enum CalibrationStats {

    // MARK: Cohen's κ

    /// Cohen's κ for two raters over the same set of items, each labelled from a shared nominal
    /// category set. `pairs` is `(rater A label, rater B label)` per item.
    ///
    /// κ = (pₒ − pₑ) / (1 − pₑ), where pₒ is the observed agreement fraction and pₑ is the
    /// agreement expected from the two raters' marginal label frequencies. Returns `nil` for an
    /// empty input. When the raters never disagree *and* only ever use one label (pₑ == 1), κ is
    /// mathematically undefined (0/0); by the usual convention this returns `1.0` (perfect,
    /// if degenerate, agreement) — callers that care should also look at the raw agreement count.
    public static func cohensKappa<Label: Hashable>(_ pairs: [(Label, Label)]) -> Double? {
        guard !pairs.isEmpty else { return nil }
        let n = Double(pairs.count)

        let observedAgreement = Double(pairs.filter { $0.0 == $0.1 }.count) / n

        var marginA: [Label: Double] = [:]
        var marginB: [Label: Double] = [:]
        for (a, b) in pairs {
            marginA[a, default: 0] += 1
            marginB[b, default: 0] += 1
        }
        var expectedAgreement = 0.0
        for (label, countA) in marginA {
            let countB = marginB[label] ?? 0
            expectedAgreement += (countA / n) * (countB / n)
        }

        let denominator = 1 - expectedAgreement
        guard denominator > 1e-12 else { return observedAgreement >= 1 ? 1.0 : 0.0 }
        return (observedAgreement - expectedAgreement) / denominator
    }

    /// Landis & Koch (1977) strength-of-agreement bands, the standard reading for a κ value.
    /// Used only for the human-readable summary line, never as the gate itself.
    public static func agreementLabel(forKappa kappa: Double) -> String {
        switch kappa {
        case ..<0.0: return "poor (worse than chance)"
        case 0.0..<0.20: return "slight"
        case 0.20..<0.40: return "fair"
        case 0.40..<0.60: return "moderate"
        case 0.60..<0.80: return "substantial"
        default: return "almost perfect"
        }
    }

    // MARK: scalar error

    /// Mean absolute error between paired reals — here, the grader-derived score vs. the
    /// expert-derived score for the same answer. `nil` for an empty input.
    public static func meanAbsoluteError(_ pairs: [(Double, Double)]) -> Double? {
        guard !pairs.isEmpty else { return nil }
        return pairs.reduce(0.0) { $0 + abs($1.0 - $1.1) } / Double(pairs.count)
    }

    /// Root-mean-square error between paired reals — reported alongside MAE because it exposes a
    /// few large disagreements that MAE alone would average away. `nil` for an empty input.
    public static func rootMeanSquareError(_ pairs: [(Double, Double)]) -> Double? {
        guard !pairs.isEmpty else { return nil }
        let sumSquares = pairs.reduce(0.0) { $0 + ($1.0 - $1.1) * ($1.0 - $1.1) }
        return (sumSquares / Double(pairs.count)).squareRoot()
    }

    // MARK: confusion matrix

    /// A square confusion matrix over an ordered category list. `cell(expected:actual:)` is the
    /// count of items the reference rater put in `expected` and the system put in `actual`; the
    /// diagonal is agreement.
    public struct ConfusionMatrix<Category: Hashable>: Equatable {
        public let categories: [Category]
        /// `counts[i][j]` = expected `categories[i]`, actual `categories[j]`.
        public let counts: [[Int]]

        public func count(expected: Category, actual: Category) -> Int {
            guard let i = categories.firstIndex(of: expected),
                  let j = categories.firstIndex(of: actual) else { return 0 }
            return counts[i][j]
        }

        public var total: Int { counts.reduce(0) { $0 + $1.reduce(0, +) } }

        /// Fraction on the diagonal (overall agreement). `nil` when the matrix is empty.
        public var accuracy: Double? {
            let t = total
            guard t > 0 else { return nil }
            let onDiagonal = categories.indices.reduce(0) { $0 + counts[$1][$1] }
            return Double(onDiagonal) / Double(t)
        }
    }

    /// Build a confusion matrix from `(expected, actual)` pairs. Any pair whose label is not in
    /// `categories` is ignored (the caller decides the category set — e.g. dropping `ambiguous`).
    public static func confusionMatrix<Category: Hashable>(
        _ pairs: [(expected: Category, actual: Category)], categories: [Category]
    ) -> ConfusionMatrix<Category> {
        let index = Dictionary(uniqueKeysWithValues: categories.enumerated().map { ($1, $0) })
        var counts = Array(repeating: Array(repeating: 0, count: categories.count), count: categories.count)
        for pair in pairs {
            guard let i = index[pair.expected], let j = index[pair.actual] else { continue }
            counts[i][j] += 1
        }
        return ConfusionMatrix(categories: categories, counts: counts)
    }
}
