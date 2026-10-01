import XCTest
@testable import OrionCodeIntel
@testable import OrionCore

/// Docs/17 M3: `RubricGrader` orchestration — k-sampled judging, aggregation, misconception
/// lifecycle, persistence — with a scripted judge/comparer, no model.
final class RubricGraderTests: XCTestCase {

    /// Replays a per-criterion script of verdicts round-robin (so k=3 can see a split).
    private final class ScriptedJudge: CriterionJudging, @unchecked Sendable {
        let source: TeachingQuestionSource
        let byText: [String: [CriterionVerdict]]
        var calls: [String: Int] = [:]
        init(source: TeachingQuestionSource = .local, _ byText: [String: [CriterionVerdict]]) {
            self.source = source
            self.byText = byText
        }
        func judge(criterionText: String, criterionKind: RubricCriterionKind, answer: String,
                   conceptEvidence: [String]) async throws -> CriterionVerdict {
            let seq = byText[criterionText] ?? [CriterionVerdict(met: false, confidence: .low)]
            let i = calls[criterionText, default: 0]
            calls[criterionText] = i + 1
            return seq[i % seq.count]
        }
    }

    private struct FixedComparer: AnswerComparing {
        let same: Bool
        func conveysSameIdea(_ a: String, as b: String) async throws -> Bool { same }
    }

    private func met(_ c: GraderConfidence = .high) -> CriterionVerdict {
        CriterionVerdict(met: true, confidence: c, evidenceQuote: "quote", note: "n")
    }
    private func notMet(_ c: GraderConfidence = .high) -> CriterionVerdict {
        CriterionVerdict(met: false, confidence: c, evidenceQuote: "", note: "n")
    }

    private func seed(
        criteria: [(kind: String, text: String)]
    ) throws -> (store: Store, run: AnalysisRunRecord, questionId: String) {
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
            id: "k1", repositoryId: "repo", kind: "component", subjectLabel: "Routing",
            evidenceAnchors: [], centrality: 0.5, difficultyBand: 1, createdAt: "t0")])
        try store.insertTeachingQuestion(TeachingQuestionRecord(
            id: "q1", conceptId: "k1", difficultyBand: 1, explain: "e",
            prompt: "How does Router pick a Route?",
            referenceAnswer: "Router tries its routes in declaration order and takes the first match.",
            generatedBy: "local", verified: true, createdAt: "t0"))
        try store.insertTeachingRubricCriteria(criteria.enumerated().map { i, c in
            TeachingRubricCriterionRecord(id: "cr\(i)", questionId: "q1", ordinal: i, kind: c.kind,
                                          text: c.text, evidenceAnchors: [])
        })
        return (store, try XCTUnwrap(store.run(id: "run")), "q1")
    }

    private func grade(
        _ f: (store: Store, run: AnalysisRunRecord, questionId: String),
        judge: any CriterionJudging, comparer: (any AnswerComparing)? = nil,
        persistMastery: Bool = true, answer: String = "an answer"
    ) async throws -> RubricGrader.Result {
        try await RubricGrader(
            store: f.store, run: f.run, judge: judge, comparer: comparer, k: 3,
            persistMastery: persistMastery, now: { "tX" }
        ).grade(questionId: f.questionId, answer: answer)
    }

    func testPersistMasteryFalseGradesTheAttemptButTouchesNoKnowledgeState() async throws {
        let f = try seed(criteria: [("required", "R1"), ("anti", "Wrong idea Z.")])
        let judge = ScriptedJudge(["R1": [met()], "Wrong idea Z.": [met()]])
        let r = try await grade(f, judge: judge, persistMastery: false)

        // The attempt + criterion results are still the auditable record.
        XCTAssertNotNil(try f.store.teachingAttempt(id: r.attemptId))
        XCTAssertEqual(try f.store.teachingCriterionResults(attemptId: r.attemptId).count, 2)
        // …but nothing moved in knowledge_states, and no misconception row was written.
        XCTAssertNil(try f.store.knowledgeState(conceptId: "k1"))
        XCTAssertNil(r.knowledgeState)
        // The tripped anti-criterion is still surfaced in-memory for the UI to show.
        XCTAssertEqual(r.misconceptionsDetected, ["Wrong idea Z."])
    }

    func testAllRequiredMetPersistsSolidAttemptAndResults() async throws {
        let f = try seed(criteria: [
            ("required", "R1"), ("required", "R2"), ("bonus", "B1"), ("anti", "A1"),
        ])
        let judge = ScriptedJudge([
            "R1": [met()], "R2": [met()], "B1": [met()], "A1": [notMet()],
        ])
        let r = try await grade(f, judge: judge)
        XCTAssertEqual(r.verdict, .solid)
        XCTAssertEqual([r.requiredMet, r.requiredTotal, r.bonusMet, r.antiTripped], [2, 2, 1, 0])

        let attempt = try XCTUnwrap(f.store.teachingAttempt(id: r.attemptId))
        XCTAssertEqual(attempt.verdictTier, "solid")
        XCTAssertEqual(attempt.modelUsed, "local")
        XCTAssertFalse(attempt.disputed)

        let results = try f.store.teachingCriterionResults(attemptId: r.attemptId)
        XCTAssertEqual(results.count, 4)
        let r1 = try XCTUnwrap(results.first { $0.criterionId == "cr0" })
        XCTAssertTrue(r1.met)
        // vote_detail carries the k=3 samples.
        let votes = try JSONSerialization.jsonObject(with: Data((r1.voteDetail ?? "").utf8)) as? [[String: Any]]
        XCTAssertEqual(votes?.count, 3)
    }

    /// Throws on the listed call numbers (1-based, per criterion) and otherwise replays `verdict`.
    private final class FlakyJudge: CriterionJudging, @unchecked Sendable {
        struct Failure: Error {}
        let source: TeachingQuestionSource = .local
        let failOn: [String: Set<Int>]
        let verdict: CriterionVerdict
        var calls: [String: Int] = [:]
        init(failOn: [String: Set<Int>], verdict: CriterionVerdict) {
            self.failOn = failOn
            self.verdict = verdict
        }
        func judge(criterionText: String, criterionKind: RubricCriterionKind, answer: String,
                   conceptEvidence: [String]) async throws -> CriterionVerdict {
            let n = calls[criterionText, default: 0] + 1
            calls[criterionText] = n
            if failOn[criterionText]?.contains(n) == true { throw Failure() }
            return verdict
        }
    }

    private struct ThrowingComparer: AnswerComparing {
        func conveysSameIdea(_ a: String, as b: String) async throws -> Bool { throw FlakyJudge.Failure() }
    }

    /// Docs/18 M5 hardening: Docs/18 M4 saw one Core AI judge call end with no response, which
    /// used to fail the whole grade. A failed call is now one unconfident "not met" vote.
    func testAFailedJudgeCallIsAnUnconfidentVoteNotAFailedGrade() async throws {
        let f = try seed(criteria: [("required", "R1"), ("required", "R2")])
        let judge = FlakyJudge(failOn: ["R2": [2]], verdict: met())
        let r = try await grade(f, judge: judge)
        // R2: met, <failed>, met -> majority met but split -> low confidence, needs review.
        XCTAssertEqual([r.requiredMet, r.requiredTotal], [1, 1])
        XCTAssertEqual(r.needsReview, ["R2"])
        let cr2 = try XCTUnwrap(
            try f.store.teachingCriterionResults(attemptId: r.attemptId).first { $0.criterionId == "cr1" })
        let votes = try JSONSerialization.jsonObject(with: Data((cr2.voteDetail ?? "").utf8)) as? [[String: Any]]
        XCTAssertEqual(votes?.map { $0["met"] as? Bool }, [true, false, true])
        XCTAssertEqual(votes?[1]["confidence"] as? String, "low", "the failed call is an unconfident vote")
    }

    func testAllVotesFailingLeavesTheCriterionUnconfidentAndNotMet() async throws {
        let f = try seed(criteria: [("required", "R1"), ("required", "R2")])
        let r = try await grade(f, judge: FlakyJudge(failOn: ["R2": [1, 2, 3]], verdict: met()))
        XCTAssertEqual(r.needsReview, ["R2"])
        let cr2 = try XCTUnwrap(
            try f.store.teachingCriterionResults(attemptId: r.attemptId).first { $0.criterionId == "cr1" })
        XCTAssertFalse(cr2.met)
        XCTAssertEqual(cr2.confidence, "low")
    }

    func testAFailedComparerLeavesTheTripwireUnrunInsteadOfFailingTheGrade() async throws {
        let f = try seed(criteria: [("required", "R1")])
        let r = try await grade(f, judge: ScriptedJudge(["R1": [met()]]), comparer: ThrowingComparer())
        XCTAssertEqual(r.verdict, .solid)
        XCTAssertNil(r.pairwiseSameIdea)
        XCTAssertFalse(r.disputed)
    }

    func testSplitVoteOnRequiredIsLowConfidenceAndExcluded() async throws {
        let f = try seed(criteria: [("required", "R1"), ("required", "R2")])
        // R2's three k-calls: met, not-met, met -> majority met but NOT unanimous -> low, excluded.
        let judge = ScriptedJudge(["R1": [met()], "R2": [met(), notMet(), met()]])
        let r = try await grade(f, judge: judge)
        XCTAssertEqual([r.requiredMet, r.requiredTotal], [1, 1])
        XCTAssertEqual(r.needsReview, ["R2"])
        let cr2 = try XCTUnwrap(
            try f.store.teachingCriterionResults(attemptId: r.attemptId).first { $0.criterionId == "cr1" })
        XCTAssertEqual(cr2.confidence, "low")
    }

    func testAntiTrippedRecordsMisconceptionAndKnowledgeState() async throws {
        let f = try seed(criteria: [("required", "R1"), ("anti", "Believes routes match by specificity.")])
        let judge = ScriptedJudge(["R1": [met()], "Believes routes match by specificity.": [met()]])
        let r = try await grade(f, judge: judge)
        XCTAssertEqual(r.antiTripped, 1)
        XCTAssertEqual(r.misconceptionsDetected, ["Believes routes match by specificity."])

        let ks = try XCTUnwrap(f.store.knowledgeState(conceptId: "k1"))
        // M4: the mastery update now runs on every attempt. One `required` met + one tripped anti
        // from the 0.15 prior lands below 0.5, attempts=1 so the band stays `new`.
        XCTAssertEqual(ks.attemptsCount, 1)
        XCTAssertEqual(ks.confidenceBand, "new")
        XCTAssertLessThan(ks.pMastered, 0.5)
        XCTAssertEqual(ks.lastVerdict, r.verdict.rawValue)
        XCTAssertNotNil(r.knowledgeState)
        let open = try f.store.teachingMisconceptions(knowledgeStateId: ks.id, openOnly: true)
        XCTAssertEqual(open.map(\.statement), ["Believes routes match by specificity."])
    }

    func testMisconceptionClearedOnLaterConfidentNotMet() async throws {
        let f = try seed(criteria: [("required", "R1"), ("anti", "Wrong idea X.")])
        _ = try await grade(f, judge: ScriptedJudge(["R1": [met()], "Wrong idea X.": [met()]]))
        let ks = try XCTUnwrap(f.store.knowledgeState(conceptId: "k1"))
        XCTAssertEqual(try f.store.teachingMisconceptions(knowledgeStateId: ks.id, openOnly: true).count, 1)

        let second = try await grade(
            f, judge: ScriptedJudge(["R1": [met()], "Wrong idea X.": [notMet(.high)]]))
        XCTAssertEqual(second.misconceptionsCleared, ["Wrong idea X."])
        XCTAssertEqual(try f.store.teachingMisconceptions(knowledgeStateId: ks.id, openOnly: true).count, 0)
    }

    func testMisconceptionNotDoubleRecordedAcrossAttempts() async throws {
        let f = try seed(criteria: [("required", "R1"), ("anti", "Wrong idea Y.")])
        let judge = ScriptedJudge(["R1": [met()], "Wrong idea Y.": [met()]])
        _ = try await grade(f, judge: judge)
        let second = try await grade(f, judge: ScriptedJudge(["R1": [met()], "Wrong idea Y.": [met()]]))
        XCTAssertTrue(second.misconceptionsDetected.isEmpty)   // already open
        let ks = try XCTUnwrap(f.store.knowledgeState(conceptId: "k1"))
        XCTAssertEqual(try f.store.teachingMisconceptions(knowledgeStateId: ks.id).count, 1)
    }

    func testPairwiseDisagreementFlagsDisputedAndWritesDiagnostic() async throws {
        let f = try seed(criteria: [("required", "R1"), ("required", "R2")])
        let judge = ScriptedJudge(["R1": [met()], "R2": [met()]])   // rubric score 1.0
        let r = try await grade(f, judge: judge, comparer: FixedComparer(same: false))
        XCTAssertTrue(r.disputed)
        XCTAssertEqual(r.pairwiseSameIdea, false)
        XCTAssertTrue(try XCTUnwrap(f.store.teachingAttempt(id: r.attemptId)).disputed)
        XCTAssertTrue(try f.store.diagnostics(runId: "run").contains {
            $0.stage == "teaching_grade" && $0.code == RubricGrader.disputedDiagnosticCode
        })
    }

    func testPairwiseAgreementNoDispute() async throws {
        let f = try seed(criteria: [("required", "R1"), ("required", "R2")])
        let r = try await grade(f, judge: ScriptedJudge(["R1": [met()], "R2": [met()]]),
                                comparer: FixedComparer(same: true))
        XCTAssertFalse(r.disputed)
    }

    func testGradeThrowsForUnknownQuestion() async throws {
        let f = try seed(criteria: [("required", "R1")])
        let grader = RubricGrader(store: f.store, run: f.run, judge: ScriptedJudge([:]), k: 3)
        await XCTAssertThrowsErrorAsync(try await grader.grade(questionId: "nope", answer: "x"))
    }
}

/// Small async throwing-assert helper (this suite has no shared one).
func XCTAssertThrowsErrorAsync(
    _ expression: @autoclosure () async throws -> some Any,
    _ message: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail(message().isEmpty ? "expected an error" : message(), file: file, line: line)
    } catch {}
}
