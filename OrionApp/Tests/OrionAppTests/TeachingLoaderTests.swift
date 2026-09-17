import XCTest

@testable import Orion
import OrionAgent
import OrionCodeIntel

/// Docs/17_phase7_teaching_mode.md M6: `TeachingLoader` against a real analyzed fixture repo with
/// hand-seeded Phase 7 rows — the pure projection logic (concept rows ordered by planner rank,
/// the overview counts, the graded-attempt card) with no SwiftUI and no model.
final class TeachingLoaderTests: XCTestCase {

    private struct ScriptedJudge: CriterionJudging {
        let source: TeachingQuestionSource = .local
        let verdicts: [String: CriterionVerdict]
        func judge(
            criterionText: String, criterionKind: RubricCriterionKind, answer: String,
            conceptEvidence: [String]
        ) async throws -> CriterionVerdict {
            verdicts[criterionText] ?? CriterionVerdict(met: false, confidence: .low)
        }
    }

    private func makeRepo() throws -> (repoRoot: URL, outputDirectory: URL, run: AnalysisRunRecord, store: Store) {
        let repoRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("TeachingLoaderTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: repoRoot, withIntermediateDirectories: true)
        try "class Router:\n    pass\n\nclass Route:\n    pass\n".write(
            to: repoRoot.appendingPathComponent("routing.py"), atomically: true, encoding: .utf8)
        let outputDirectory = RepositorySession.outputDirectory(forRepoRoot: repoRoot)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let db = try OrionDatabase(path: outputDirectory.appendingPathComponent("orion.db").path)
        _ = try AnalysisPipeline(database: db).run(
            AnalysisInput(repoPath: repoRoot, outputDirectory: outputDirectory, resolve: false))
        let store = Store(db)
        let run = try XCTUnwrap(store.latestRun(commitHash: nil))
        return (repoRoot, outputDirectory, run, store)
    }

    private func seedConcept(
        _ store: Store, repositoryId: String, id: String, label: String, kind: String = "component",
        band: Int = 1, centrality: Double = 0.5
    ) throws {
        try store.insertTeachingConcepts([
            TeachingConceptRecord(
                id: id, repositoryId: repositoryId, kind: kind, subjectLabel: label,
                evidenceAnchors: [], centrality: centrality, difficultyBand: band, createdAt: "t0")
        ])
    }

    private func seedKnowledge(
        _ store: Store, conceptId: String, p: Double, band: String, attempts: Int,
        lastVerdict: String? = nil
    ) throws {
        try store.insertKnowledgeState(
            KnowledgeStateRecord(
                id: "ks-\(conceptId)", conceptId: conceptId, pMastered: p, attemptsCount: attempts,
                lastVerdict: lastVerdict, confidenceBand: band, firstSeenAt: "t0", lastAssessedAt: "t0"))
    }

    func testConceptsCarryMasteryAndAreOrderedByPlannerRank() throws {
        let (_, outputDirectory, run, store) = try makeRepo()
        try seedConcept(store, repositoryId: run.repositoryId, id: "hi", label: "Routing", centrality: 0.9)
        try seedConcept(store, repositoryId: run.repositoryId, id: "lo", label: "Config", centrality: 0.1)
        try seedKnowledge(store, conceptId: "lo", p: 0.2, band: "shaky", attempts: 2, lastVerdict: "partial")

        let rows = try TeachingLoader.concepts(outputDirectory: outputDirectory, bootstrap: false)
        XCTAssertEqual(rows.map(\.id), ["hi", "lo"])   // higher centrality × (1 - p) ranks first
        let lo = try XCTUnwrap(rows.first { $0.id == "lo" })
        XCTAssertEqual(lo.confidenceBand, "shaky")
        XCTAssertEqual(lo.attempts, 2)
        XCTAssertEqual(lo.lastVerdict, "partial")
        let hi = try XCTUnwrap(rows.first { $0.id == "hi" })
        XCTAssertEqual(hi.pMastered, 0.15, accuracy: 1e-9)   // never assessed -> prior
        XCTAssertEqual(hi.confidenceBand, "new")
    }

    func testOpenMisconceptionSurfacesOnTheRow() throws {
        let (_, outputDirectory, run, store) = try makeRepo()
        try seedConcept(store, repositoryId: run.repositoryId, id: "c1", label: "Routing")
        try seedKnowledge(store, conceptId: "c1", p: 0.3, band: "shaky", attempts: 1)
        try store.insertTeachingQuestion(
            TeachingQuestionRecord(
                id: "q1", conceptId: "c1", difficultyBand: 1, explain: "e", prompt: "p",
                referenceAnswer: "a reference answer that is definitely long enough",
                generatedBy: "local", verified: true, createdAt: "t0"))
        try store.insertTeachingRubricCriteria([
            TeachingRubricCriterionRecord(id: "cr", questionId: "q1", ordinal: 0, kind: "anti",
                                          text: "matches by specificity", evidenceAnchors: [])
        ])
        try store.insertTeachingAttempt(
            TeachingAttemptRecord(id: "a1", questionId: "q1", answerText: "x", score: 0,
                                  verdictTier: "off-track", createdAt: "t1"))
        try store.insertTeachingMisconception(
            TeachingMisconceptionRecord(
                id: "m1", knowledgeStateId: "ks-c1", criterionId: "cr", attemptId: "a1",
                statement: "Believes routes match by specificity.", detectedAt: "t1"))

        let rows = try TeachingLoader.concepts(outputDirectory: outputDirectory, bootstrap: false)
        let c1 = try XCTUnwrap(rows.first { $0.id == "c1" })
        XCTAssertTrue(c1.hasOpenMisconception)
        XCTAssertEqual(c1.openMisconceptions, ["Believes routes match by specificity."])
    }

    func testOverviewCountsBands() throws {
        let rows = [
            makeRow(band: "solid"), makeRow(band: "solid"), makeRow(band: "developing"),
            makeRow(band: "shaky"), makeRow(band: "new"), makeRow(band: "shaky", misconception: true),
        ]
        let o = TeachingLoader.overview(from: rows)
        XCTAssertEqual([o.total, o.solid, o.developing, o.shaky, o.new, o.misconceptionConcepts],
                       [6, 2, 1, 2, 1, 1])
        XCTAssertFalse(o.isEmpty)
        XCTAssertTrue(TeachingLoader.overview(from: []).isEmpty)
    }

    func testLatestVerifiedQuestionMatchesBandWhenAsked() throws {
        let (_, outputDirectory, run, store) = try makeRepo()
        try seedConcept(store, repositoryId: run.repositoryId, id: "c1", label: "Routing")
        for (id, band) in [("qA", 1), ("qB", 2), ("qC", 1)] {
            try store.insertTeachingQuestion(
                TeachingQuestionRecord(
                    id: id, conceptId: "c1", difficultyBand: band, explain: "e", prompt: "prompt \(id)",
                    referenceAnswer: "a reference answer that is definitely long enough",
                    generatedBy: "local", verified: true, createdAt: "t\(id)"))
        }
        let any = try TeachingLoader.latestVerifiedQuestion(
            conceptId: "c1", band: nil, outputDirectory: outputDirectory)
        XCTAssertEqual(any?.id, "qC")   // newest overall
        let band2 = try TeachingLoader.latestVerifiedQuestion(
            conceptId: "c1", band: 2, outputDirectory: outputDirectory)
        XCTAssertEqual(band2?.id, "qB")
    }

    func testGradeCardMapsCriteriaAndCalibrationSuppressesMastery() async throws {
        let (repoRoot, outputDirectory, run, store) = try makeRepo()
        _ = repoRoot
        try seedConcept(store, repositoryId: run.repositoryId, id: "c1", label: "Routing")
        try store.insertTeachingQuestion(
            TeachingQuestionRecord(
                id: "q1", conceptId: "c1", difficultyBand: 1, explain: "e",
                prompt: "How does Router pick a Route?",
                referenceAnswer: "It iterates its routes in declaration order and takes the first match.",
                generatedBy: "local", verified: true, createdAt: "t0"))
        try store.insertTeachingRubricCriteria([
            TeachingRubricCriterionRecord(id: "cr0", questionId: "q1", ordinal: 0, kind: "required",
                text: "States declaration order.", evidenceAnchors: ["routing.py::Router"]),
            TeachingRubricCriterionRecord(id: "cr1", questionId: "q1", ordinal: 1, kind: "anti",
                text: "Claims specificity ranking.", evidenceAnchors: []),
        ])

        let judge = ScriptedJudge(verdicts: [
            "States declaration order.": CriterionVerdict(
                met: true, confidence: .high, evidenceQuote: "in order", note: "explicit"),
            "Claims specificity ranking.": CriterionVerdict(met: false, confidence: .high),
        ])
        let result = try await RubricGrader(
            store: store, run: run, judge: judge, k: 3, persistMastery: false, now: { "tX" }
        ).grade(questionId: "q1", answer: "Router walks its route list in order.")

        let card = try TeachingLoader.gradeCard(result, outputDirectory: outputDirectory)
        XCTAssertEqual(card.verdict, "solid")
        XCTAssertEqual(card.requiredMet, 1)
        XCTAssertEqual(card.requiredTotal, 1)
        // The anti criterion (not met) is still in the projected list; the view filters it.
        XCTAssertEqual(card.criteria.map(\.kind), [.required, .anti])
        let required = try XCTUnwrap(card.criteria.first { $0.kind == .required })
        XCTAssertTrue(required.met)
        XCTAssertEqual(required.evidenceQuote, "in order")
        XCTAssertEqual(required.evidence.map(\.anchor), ["routing.py::Router"])
        XCTAssertNotNil(required.evidence.first?.startLine)   // resolved against the real run
        // Calibration gate: persistMastery:false -> no mastery move projected.
        XCTAssertNil(card.masteryAfter)
        XCTAssertNil(card.bandAfter)
    }

    private func makeRow(band: String, misconception: Bool = false) -> TeachingConceptRow {
        TeachingConceptRow(
            id: UUID().uuidString, label: "x", kind: "component", difficultyBand: 1, centrality: 0.5,
            pMastered: 0.5, confidenceBand: band, attempts: 1, lastVerdict: nil,
            openMisconceptions: misconception ? ["m"] : [], plannerScore: 0)
    }
}
