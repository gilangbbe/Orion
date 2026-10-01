import Foundation

/// Ported from Phase 2 M5's `score.py`
/// (`Agent Feasibility Study/harness/orion_eval/semantic/score.py`) — normalization + greedy
/// Jaccard alignment between two independently-produced, anchor-labeled sets with no shared
/// stable identity. Originally built to compare a *predicted* component decomposition against a
/// *gold* one (Docs/11 M5); `RevisionDiffer` (Docs/16 §4, M2) reuses it to compare one
/// investigation's components/claims against another's, for the same underlying reason: "close
/// enough" must count as a match, since neither side can be assumed to use the other's exact
/// vocabulary or anchor granularity (Docs/16 Decision #4). The Python original stays exactly
/// as-is for Phase 2's own reproducibility — this is a port, not a shared implementation, the
/// same "port, don't extend the Python side further" precedent Phase 3 set when it ported
/// `investigate.py`'s CLI contract into Swift (Docs/12 Decision 3).
public enum AnchorAlignment {

    /// The Jaccard overlap needed to count two anchor sets as "the same" — matches `score.py`'s
    /// own `MATCH_THRESHOLD`.
    public static let defaultThreshold: Double = 0.3

    /// Rolls an anchor up to its top-level defining symbol: `path::Class.method` ->
    /// `path::Class`; a bare module path (no `::`) is unchanged. Ported verbatim from
    /// `normalize_anchor` — needed because a later investigation routinely cites a more (or
    /// less) specific anchor than an earlier one for the same subject, and without this the
    /// overlap comparison would penalize a claim for being more specific than what it's being
    /// compared against, rather than measuring whether it's actually the same thing.
    public static func normalize(_ anchor: String) -> String {
        guard let separator = anchor.range(of: "::") else { return anchor }
        let path = anchor[anchor.startIndex..<separator.lowerBound]
        let dotted = anchor[separator.upperBound...]
        let top = dotted.split(separator: ".", maxSplits: 1).first.map(String.init) ?? String(dotted)
        return "\(path)::\(top)"
    }

    /// `normalize(_:)` applied to a whole collection of anchors, deduplicated.
    public static func normalizedSet<S: Sequence>(_ anchors: S) -> Set<String> where S.Element == String {
        Set(anchors.map(normalize))
    }

    /// Ported verbatim from `jaccard` — two empty sets are defined as identical (`1.0`), matching
    /// the Python original's own convention (an entity cited with zero anchors is trivially "the
    /// same" as another cited with zero anchors, rather than an undefined `0/0`).
    public static func jaccard(_ a: Set<String>, _ b: Set<String>) -> Double {
        if a.isEmpty && b.isEmpty { return 1.0 }
        let union = a.union(b)
        guard !union.isEmpty else { return 0.0 }
        return Double(a.intersection(b).count) / Double(union.count)
    }

    /// One matched pair from `align(lhs:rhs:threshold:)` — mirrors `score.py`'s own
    /// `ComponentMatch`, generalized past components (`RevisionDiffer`, Docs/16 M2, uses this same
    /// shape for claims too). Anchor sets here are already normalized.
    ///
    /// This is a real, deliberate enrichment over Docs/16 §3's own original sketch (a bare
    /// `[(T, T)]` of matched id pairs) — `lhsOnly`/`rhsOnly`/`precision`/`recall` are exactly what
    /// `RevisionDiffer`'s deterministic reason templating (§4.2/§4.3) needs to say *what* changed
    /// ("evidence now includes {rhsOnly}"), not just *that* two things matched. Kept here rather
    /// than recomputed by every caller.
    public struct Match<T> {
        public let lhsId: T
        public let rhsId: T
        public let jaccard: Double
        /// `|intersection| / |rhs set|` — of what the rhs side asserts, how much the lhs side
        /// also has.
        public let precision: Double
        /// `|intersection| / |lhs set|` — of what the lhs side asserts, how much the rhs side
        /// also has.
        public let recall: Double
        public let f1: Double
        public let intersection: Set<String>
        /// Normalized anchors the lhs side has that the rhs side doesn't.
        public let lhsOnly: Set<String>
        /// Normalized anchors the rhs side has that the lhs side doesn't.
        public let rhsOnly: Set<String>
    }

    public struct AlignmentResult<T> {
        public let matches: [Match<T>]
        /// lhs entries with no rhs match at or above `threshold`.
        public let unmatchedLhs: [T]
        /// rhs entries with no lhs match at or above `threshold`.
        public let unmatchedRhs: [T]
    }

    /// Greedy best-match alignment: repeatedly takes the highest-Jaccard `(lhs, rhs)` pair at or
    /// above `threshold` that hasn't used either side yet — ported verbatim from
    /// `score_components`'s own algorithm, including its "whatever's left over on either side is
    /// unmatched, not forced into a worse match" behavior. Callers pass raw anchors; normalization
    /// happens internally, so a caller never has to remember to normalize first.
    public static func align<T: Hashable>(
        lhs: [(id: T, anchors: Set<String>)],
        rhs: [(id: T, anchors: Set<String>)],
        threshold: Double = defaultThreshold
    ) -> AlignmentResult<T> {
        let lhsSets = lhs.map { (id: $0.id, set: normalizedSet($0.anchors)) }
        let rhsSets = rhs.map { (id: $0.id, set: normalizedSet($0.anchors)) }

        var candidates: [(score: Double, lhsIndex: Int, rhsIndex: Int)] = []
        for (li, l) in lhsSets.enumerated() {
            for (ri, r) in rhsSets.enumerated() {
                let score = jaccard(l.set, r.set)
                if score >= threshold {
                    candidates.append((score, li, ri))
                }
            }
        }
        // Stable sort (Swift's `sort`/`sorted` has been guaranteed stable since Swift 5), so tied
        // scores keep the original lhs-then-rhs enumeration order — matching Python's own
        // Timsort-stable `pairs.sort(key=..., reverse=True)`.
        candidates.sort { $0.score > $1.score }

        var usedLhs = Set<Int>()
        var usedRhs = Set<Int>()
        var matches: [Match<T>] = []
        for candidate in candidates {
            guard !usedLhs.contains(candidate.lhsIndex), !usedRhs.contains(candidate.rhsIndex)
            else { continue }
            usedLhs.insert(candidate.lhsIndex)
            usedRhs.insert(candidate.rhsIndex)

            let l = lhsSets[candidate.lhsIndex]
            let r = rhsSets[candidate.rhsIndex]
            let intersection = l.set.intersection(r.set)
            let precision = r.set.isEmpty ? 0.0 : Double(intersection.count) / Double(r.set.count)
            let recall = l.set.isEmpty ? 0.0 : Double(intersection.count) / Double(l.set.count)
            let f1 = (precision + recall) > 0 ? 2 * precision * recall / (precision + recall) : 0.0
            matches.append(Match(
                lhsId: l.id, rhsId: r.id, jaccard: candidate.score,
                precision: precision, recall: recall, f1: f1,
                intersection: intersection,
                lhsOnly: l.set.subtracting(r.set), rhsOnly: r.set.subtracting(l.set)
            ))
        }

        let unmatchedLhs = lhsSets.enumerated().filter { !usedLhs.contains($0.offset) }.map(\.element.id)
        let unmatchedRhs = rhsSets.enumerated().filter { !usedRhs.contains($0.offset) }.map(\.element.id)
        return AlignmentResult(matches: matches, unmatchedLhs: unmatchedLhs, unmatchedRhs: unmatchedRhs)
    }
}
