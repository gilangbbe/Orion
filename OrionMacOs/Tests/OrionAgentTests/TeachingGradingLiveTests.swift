import XCTest
@testable import OrionCodeIntel
@testable import OrionAgent

/// Docs/17 M3's "one live grade of a good/bad answer pair". Costs a real Core AI model load, so
/// it is `XCTSkip`'d unless `ORION_TEACHING_LIVE_GRADE=1`. Also in CI's `--skip` set. Plain
/// SwiftPM since Docs/18 M6:
///
/// ```
/// ORION_TEACHING_LIVE_GRADE=1 swift test --filter TeachingGradingLiveTests
/// ```
final class TeachingGradingLiveTests: XCTestCase {

    private func fixture() throws -> (store: Store, run: AnalysisRunRecord, questionId: String) {
        let db = try OrionDatabase(inMemory: true)
        let store = Store(db)
        try db.dbQueue.write { dbc in
            try RepositoryRecord(
                id: "repo", sourceURL: nil, localPath: "/x", commitHash: "c0ffee",
                languages: ["python"], analysisStatus: .succeeded, createdAt: "t0", updatedAt: "t0"
            ).insert(dbc)
            try AnalysisRunRecord(
                id: "run", repositoryId: "repo", commitHash: "c0ffee", status: "succeeded",
                startedAt: "t0", finishedAt: "t1", orionVersion: "0.1.0", resolver: "none",
                grammarVersions: [:], toolVersions: [:], stageTimings: [:], fileCount: 0,
                symbolCount: 0, relationshipCount: 0, diagnosticCount: 0, error: nil
            ).insert(dbc)
        }
        try store.insertTeachingConcepts([TeachingConceptRecord(
            id: "k1", repositoryId: "repo", kind: "claim", subjectLabel: "Router dispatch order",
            evidenceAnchors: [], centrality: 0.5, difficultyBand: 1, createdAt: "t0")])
        try store.insertTeachingQuestion(TeachingQuestionRecord(
            id: "q1", conceptId: "k1", difficultyBand: 1, explain: "Router is the dispatch entry point.",
            prompt: "How does Router decide which Route handles an incoming request?",
            referenceAnswer: "Router iterates its list of Route objects in the order they were declared and dispatches to the first one whose path and method match; it does not rank by specificity.",
            generatedBy: "local", verified: true, createdAt: "t0"))
        try store.insertTeachingRubricCriteria([
            TeachingRubricCriterionRecord(id: "cr0", questionId: "q1", ordinal: 0, kind: "required",
                text: "States that routes are checked in the order they were declared / registered.", evidenceAnchors: []),
            TeachingRubricCriterionRecord(id: "cr1", questionId: "q1", ordinal: 1, kind: "required",
                text: "States that the first matching route wins (no further routes are tried).", evidenceAnchors: []),
            TeachingRubricCriterionRecord(id: "cr2", questionId: "q1", ordinal: 2, kind: "anti",
                text: "Claims routes are ranked by specificity or longest-prefix match.", evidenceAnchors: []),
        ])
        return (store, try XCTUnwrap(store.run(id: "run")), "q1")
    }

    func testGoodAnswerScoresHigherThanBad() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["ORION_TEACHING_LIVE_GRADE"] == "1")
        let f = try fixture()
        let agent = try await LocalModelLoader.shared.model(for: .defaultCoreAI, role: .judging)
        let judge = try LocalGrading.judge(agent: agent, output: .text)

        let good = try await RubricGrader(store: f.store, run: f.run, judge: judge, k: 3, now: { "t1" })
            .grade(questionId: f.questionId,
                   answer: "Router keeps its Route objects in a list in declaration order. On each "
                       + "request it walks that list and calls match on each Route; the first Route "
                       + "whose path pattern and HTTP method match handles the request and no later "
                       + "routes are consulted. Ordering, not specificity, decides.")
        let bad = try await RubricGrader(store: f.store, run: f.run, judge: judge, k: 3, now: { "t2" })
            .grade(questionId: f.questionId,
                   answer: "Router looks at all the routes and picks whichever one is the most "
                       + "specific match for the URL, similar to how CSS selectors or longest-prefix "
                       + "IP routing works.")

        print("GOOD: \(good.score) \(good.verdict)  BAD: \(bad.score) \(bad.verdict) anti=\(bad.antiTripped)")
        XCTAssertGreaterThan(good.score, bad.score)
        XCTAssertEqual(good.verdict, .solid)
        XCTAssertGreaterThanOrEqual(bad.antiTripped, 1, "the 'specificity' answer should trip the anti-criterion")
    }
}
