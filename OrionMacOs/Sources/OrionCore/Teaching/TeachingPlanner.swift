import Foundation

/// Docs/17_phase7_teaching_mode.md §8.3 — picks the next concept to teach: lowest mastery ×
/// highest architectural centrality, with a short no-immediate-repeat window and an additive
/// boost for a concept the developer currently holds a misconception about (shaky *load-bearing*
/// understanding is the priority). Pure logic over `Store`, no model.
public struct TeachingPlanner {

    /// How many additive points an uncleared misconception adds to a concept's rank (§8.3).
    public static let misconceptionBoost = 0.3
    /// Penalty multiplier for a concept selected within the recency window.
    public static let recencyPenalty = 0.1

    let store: Store
    public init(store: Store) { self.store = store }

    public struct Ranked {
        public let concept: TeachingConceptRecord
        public let score: Double
        public let pMastered: Double
        public let attemptsCount: Int
        public let hasOpenMisconception: Bool
    }

    /// - Parameter recentConceptIds: the concept ids selected in (roughly) the last 3 turns — a
    ///   concept in this set is heavily demoted so a session doesn't hammer the same one. The
    ///   caller (CLI/app session) tracks this list; the planner keeps no state.
    public func rank(
        repositoryId: String, developerId: String = "local", recentConceptIds: [String] = []
    ) throws -> [Ranked] {
        let recent = Set(recentConceptIds)
        let ranked = try store.teachingConcepts(repositoryId: repositoryId).map { concept -> Ranked in
            let ks = try store.knowledgeState(developerId: developerId, conceptId: concept.id)
            let p = ks?.pMastered ?? KnowledgeUpdate.Params().prior
            let attempts = ks?.attemptsCount ?? 0
            let hasOpen: Bool
            if let ks {
                hasOpen = try !store.teachingMisconceptions(
                    knowledgeStateId: ks.id, openOnly: true).isEmpty
            } else {
                hasOpen = false
            }
            let recencyFactor = recent.contains(concept.id) ? Self.recencyPenalty : 1.0
            let score = (1 - p) * concept.centrality * recencyFactor
                + (hasOpen ? Self.misconceptionBoost : 0)
            return Ranked(
                concept: concept, score: score, pMastered: p, attemptsCount: attempts,
                hasOpenMisconception: hasOpen)
        }
        return ranked.sorted { a, b in
            if a.score != b.score { return a.score > b.score }
            if a.attemptsCount != b.attemptsCount { return a.attemptsCount < b.attemptsCount }
            if a.concept.difficultyBand != b.concept.difficultyBand {
                return a.concept.difficultyBand < b.concept.difficultyBand
            }
            return a.concept.id < b.concept.id
        }
    }

    public func next(
        repositoryId: String, developerId: String = "local", recentConceptIds: [String] = []
    ) throws -> TeachingConceptRecord? {
        try rank(repositoryId: repositoryId, developerId: developerId, recentConceptIds: recentConceptIds)
            .first?.concept
    }
}
