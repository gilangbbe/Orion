import XCTest
@testable import OrionCodeIntel

/// Docs/17 M4 §8.3: `TeachingPlanner` next-concept ranking — fixture data, no model.
final class TeachingPlannerTests: XCTestCase {

    private func seed() throws -> Store {
        let db = try OrionDatabase(inMemory: true)
        let store = Store(db)
        try db.dbQueue.write { dbc in
            try RepositoryRecord(
                id: "repo", sourceURL: nil, localPath: "/x", commitHash: "c0ffee",
                languages: ["python"], analysisStatus: .succeeded, createdAt: "t0", updatedAt: "t0"
            ).insert(dbc)
        }
        return store
    }

    private func concept(_ store: Store, _ id: String, centrality: Double, band: Int = 1, stale: Bool = false) throws {
        try store.insertTeachingConcepts([TeachingConceptRecord(
            id: id, repositoryId: "repo", kind: "component", subjectLabel: id,
            evidenceAnchors: [], centrality: centrality, difficultyBand: band, stale: stale,
            createdAt: "t0")])
    }

    private func knowledge(
        _ store: Store, concept: String, p: Double, attempts: Int = 1,
        openMisconception: Bool = false
    ) throws {
        let ks = KnowledgeStateRecord(
            id: "ks-\(concept)", conceptId: concept, pMastered: p, attemptsCount: attempts,
            firstSeenAt: "t0", lastAssessedAt: "t0")
        try store.insertKnowledgeState(ks)
        if openMisconception {
            // needs a real criterion+attempt+question for the FKs.
            try store.insertTeachingQuestion(TeachingQuestionRecord(
                id: "q-\(concept)", conceptId: concept, difficultyBand: 1, explain: "e", prompt: "p",
                referenceAnswer: "a reference answer of sufficient length", generatedBy: "local",
                verified: true, createdAt: "t0"))
            try store.insertTeachingRubricCriteria([TeachingRubricCriterionRecord(
                id: "cr-\(concept)", questionId: "q-\(concept)", ordinal: 0, kind: "anti",
                text: "wrong idea", evidenceAnchors: [])])
            try store.insertTeachingAttempt(TeachingAttemptRecord(
                id: "at-\(concept)", questionId: "q-\(concept)", answerText: "x", score: 0,
                verdictTier: "off-track", createdAt: "t0"))
            try store.insertTeachingMisconception(TeachingMisconceptionRecord(
                id: "m-\(concept)", knowledgeStateId: ks.id, criterionId: "cr-\(concept)",
                attemptId: "at-\(concept)", statement: "wrong idea", detectedAt: "t0"))
        }
    }

    func testNeverAssessedRankedByCentrality() throws {
        let store = try seed()
        try concept(store, "hi", centrality: 0.9)
        try concept(store, "mid", centrality: 0.5)
        try concept(store, "lo", centrality: 0.1)
        let ranked = try TeachingPlanner(store: store).rank(repositoryId: "repo")
        XCTAssertEqual(ranked.map { $0.concept.id }, ["hi", "mid", "lo"])
        // score = (1 - 0.15 prior) * centrality
        XCTAssertEqual(ranked[0].score, 0.85 * 0.9, accuracy: 1e-9)
    }

    func testMasteredConceptRanksBelowShakyOneOfEqualCentrality() throws {
        let store = try seed()
        try concept(store, "mastered", centrality: 0.8)
        try concept(store, "shaky", centrality: 0.8)
        try knowledge(store, concept: "mastered", p: 0.95)
        try knowledge(store, concept: "shaky", p: 0.20)
        let ranked = try TeachingPlanner(store: store).rank(repositoryId: "repo")
        XCTAssertEqual(ranked.first?.concept.id, "shaky")
    }

    func testOpenMisconceptionAddsBoost() throws {
        let store = try seed()
        try concept(store, "plain", centrality: 0.9)          // score ≈ 0.85*0.9 = 0.765
        try concept(store, "misc", centrality: 0.3)           // base ≈ 0.85*0.3 = 0.255, +0.3 = 0.555
        try knowledge(store, concept: "misc", p: 0.15, openMisconception: true)
        let ranked = try TeachingPlanner(store: store).rank(repositoryId: "repo")
        XCTAssertTrue(ranked.first { $0.concept.id == "misc" }!.hasOpenMisconception)
        // still behind the 0.9-centrality plain concept, but the boost closed most of the gap
        XCTAssertGreaterThan(ranked.first { $0.concept.id == "misc" }!.score, 0.5)
    }

    func testRecencyPenaltyDemotesARecentlySelectedConcept() throws {
        let store = try seed()
        try concept(store, "a", centrality: 0.8)
        try concept(store, "b", centrality: 0.75)
        let planner = TeachingPlanner(store: store)
        XCTAssertEqual(try planner.next(repositoryId: "repo")?.id, "a")   // no recency -> highest centrality
        // with "a" marked recent, a's score is multiplied by 0.1 -> "b" wins despite lower centrality
        let ranked = try planner.rank(repositoryId: "repo", recentConceptIds: ["a"])
        XCTAssertEqual(ranked.first?.concept.id, "b")
    }

    func testStaleConceptsExcluded() throws {
        let store = try seed()
        try concept(store, "live", centrality: 0.2)
        try concept(store, "dead", centrality: 0.99, stale: true)
        let ranked = try TeachingPlanner(store: store).rank(repositoryId: "repo")
        XCTAssertEqual(ranked.map { $0.concept.id }, ["live"])
    }

    func testTiesBrokenByAttemptsThenBandThenId() throws {
        let store = try seed()
        // identical centrality and (prior) mastery -> identical score.
        try concept(store, "zzz", centrality: 0.5, band: 1)
        try concept(store, "aaa", centrality: 0.5, band: 3)
        try concept(store, "mmm", centrality: 0.5, band: 1)
        try knowledge(store, concept: "mmm", p: 0.15, attempts: 2)   // more attempts -> later
        let ranked = try TeachingPlanner(store: store).rank(repositoryId: "repo")
        // "aaa" and "zzz" have 0 attempts (tie), lower band first -> "zzz" (band 1) before "aaa" (band 3);
        // "mmm" has 2 attempts -> last.
        XCTAssertEqual(ranked.map { $0.concept.id }, ["zzz", "aaa", "mmm"])
    }

    func testNextReturnsTopRanked() throws {
        let store = try seed()
        try concept(store, "top", centrality: 0.9)
        try concept(store, "other", centrality: 0.1)
        XCTAssertEqual(try TeachingPlanner(store: store).next(repositoryId: "repo")?.id, "top")
    }
}
