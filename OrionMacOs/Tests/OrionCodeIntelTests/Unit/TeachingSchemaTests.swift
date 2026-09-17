import XCTest
import GRDB
@testable import OrionCodeIntel

/// Docs/17 M0: `v6_phase7_schema` applies cleanly on top of `v1`…`v5`, every Teaching Mode
/// record round-trips through its typed shape + the bare `Store` CRUD M0 adds, and the cascade /
/// `SET NULL` directions the schema comment promises actually hold. `ConceptExtractor` (M1),
/// `TeachingQuestionGenerator` (M2), `RubricGrader` (M3) and the mastery update (M4) are all
/// still unbuilt — this file exercises only the schema and CRUD M0 delivers, same shape as
/// `ModelRevisionSchemaTests`/`AskSessionSchemaTests` for Phase 6/5's own M0.
final class TeachingSchemaTests: XCTestCase {

    /// Minimal FK-satisfying chain: repository -> run -> investigation -> component + claim, for
    /// the teaching tables to hang off.
    private func seeded() throws -> (
        db: OrionDatabase, repoId: String, investigationId: String,
        componentId: String, claimId: String
    ) {
        let db = try OrionDatabase(inMemory: true)
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
            try InvestigationRecord(
                id: "inv", repositoryId: "repo", commitHash: "c0ffee", runId: "run",
                question: "phase2_semantic_grouping", complexity: "high", schemaVersion: nil,
                modelUsed: "claude-sonnet-5", toolsUsed: [], sessionId: nil, numTurns: nil,
                totalCostUsd: nil, durationMs: nil, outcome: "verified", createdAt: "t0"
            ).insert(dbc)
            try ComponentRecord(
                id: "comp1", repositoryId: "repo", commitHash: "c0ffee", runId: "run",
                investigationId: "inv", name: "Routing", description: "Matches requests to handlers.",
                architecturalRole: "core", confidence: 0.9, confidenceTier: "high",
                status: "active", epistemicType: "INTERPRETATION", provenance: "claude_code"
            ).insert(dbc)
            try ClaimRecord(
                id: "claim1", repositoryId: "repo", commitHash: "c0ffee", runId: "run",
                investigationId: "inv", subjectRef: "starlette/routing.py::Router.app",
                predicate: nil, objectRef: nil,
                statement: "Router.app dispatches to the first matching Route in declaration order.",
                claimType: "INTERPRETATION", confidence: 0.8, status: "active",
                createdBy: "claude_code"
            ).insert(dbc)
        }
        return (db, "repo", "inv", "comp1", "claim1")
    }

    /// A verified question + a `required` and an `anti` criterion, all hanging off one concept.
    private func seedConceptQuestion(
        _ store: Store, repoId: String, componentId: String, claimId: String, conceptId: String
    ) throws -> (questionId: String, requiredCriterionId: String, antiCriterionId: String) {
        try store.insertTeachingConcepts([
            TeachingConceptRecord(
                id: conceptId, repositoryId: repoId, kind: TeachingConceptKind.claim.rawValue,
                subjectLabel: "Router.app dispatch order",
                sourceComponentId: componentId, sourceClaimId: claimId,
                evidenceAnchors: ["starlette/routing.py::Router.app"],
                centrality: 0.7, difficultyBand: 2, createdAt: "t0"
            )
        ])
        try store.insertTeachingQuestion(
            TeachingQuestionRecord(
                id: "q1", conceptId: conceptId, investigationId: "inv", difficultyBand: 2,
                explain: "Router.app is the dispatch entry point.",
                prompt: "How does Router.app pick which Route handles a request?",
                referenceAnswer: "It iterates the routes in declaration order and dispatches to the first match.",
                referenceAnchors: ["starlette/routing.py::Router.app"],
                transferProblem: "What happens if two routes match the same path?",
                generatedBy: TeachingQuestionSource.local.rawValue, verified: true, createdAt: "t0"
            ))
        try store.insertTeachingRubricCriteria([
            TeachingRubricCriterionRecord(
                id: "cr1", questionId: "q1", ordinal: 0,
                kind: RubricCriterionKind.required.rawValue,
                text: "States that routes are checked in declaration order.",
                evidenceAnchors: ["starlette/routing.py::Router.app"]
            ),
            TeachingRubricCriterionRecord(
                id: "cr2", questionId: "q1", ordinal: 1, kind: RubricCriterionKind.anti.rawValue,
                text: "Claims routes are matched by specificity / longest-prefix.",
                evidenceAnchors: ["starlette/routing.py::Router.app"]
            )
        ])
        return ("q1", "cr1", "cr2")
    }

    func testV6TablesExist() throws {
        let (db, _, _, _, _) = try seeded()
        try db.dbQueue.read { dbc in
            let names = try String.fetchSet(
                dbc, sql: "SELECT name FROM sqlite_master WHERE type = 'table'")
            for t in [
                "teaching_concepts", "teaching_questions", "teaching_rubric_criteria",
                "teaching_attempts", "teaching_criterion_results", "knowledge_states",
                "teaching_misconceptions"
            ] {
                XCTAssertTrue(names.contains(t), "missing table \(t)")
            }
        }
    }

    func testPhase1Through6SuiteUnaffected() throws {
        let (db, _, invId, compId, claimId) = try seeded()
        try db.dbQueue.read { dbc in
            XCTAssertEqual(try InvestigationRecord.fetchCount(dbc), 1)
            XCTAssertEqual(try ComponentRecord.fetchCount(dbc), 1)
            XCTAssertEqual(try ClaimRecord.fetchCount(dbc), 1)
        }
        XCTAssertEqual([invId, compId, claimId], ["inv", "comp1", "claim1"])
    }

    func testConceptRoundTripIncludingJSONAnchors() throws {
        let (db, repoId, _, compId, claimId) = try seeded()
        let store = Store(db)
        try store.insertTeachingConcepts([
            TeachingConceptRecord(
                id: "k1", repositoryId: repoId, kind: TeachingConceptKind.component.rawValue,
                subjectLabel: "Routing", sourceComponentId: compId, sourceClaimId: claimId,
                evidenceAnchors: ["starlette/routing.py::Router", "starlette/routing.py::Route"],
                centrality: 0.42, difficultyBand: 1, createdAt: "t0"
            )
        ])
        let fetched = try XCTUnwrap(try store.teachingConcept(id: "k1"))
        XCTAssertEqual(fetched.kind, "component")
        XCTAssertEqual(fetched.evidenceAnchors,
                       ["starlette/routing.py::Router", "starlette/routing.py::Route"])
        XCTAssertEqual(fetched.centrality, 0.42, accuracy: 1e-9)
        XCTAssertFalse(fetched.stale)
    }

    func testTeachingConceptsReadFiltersStaleAndOrdersByCentrality() throws {
        let (db, repoId, _, _, _) = try seeded()
        let store = Store(db)
        try store.insertTeachingConcepts([
            TeachingConceptRecord(id: "low", repositoryId: repoId, kind: "role",
                                  subjectLabel: "A", centrality: 0.1, createdAt: "t0"),
            TeachingConceptRecord(id: "high", repositoryId: repoId, kind: "role",
                                  subjectLabel: "B", centrality: 0.9, createdAt: "t0"),
            TeachingConceptRecord(id: "gone", repositoryId: repoId, kind: "role",
                                  subjectLabel: "C", centrality: 0.5, stale: true, createdAt: "t0")
        ])
        XCTAssertEqual(try store.teachingConcepts(repositoryId: repoId).map(\.id), ["high", "low"])
        XCTAssertEqual(
            try store.teachingConcepts(repositoryId: repoId, includeStale: true).map(\.id),
            ["high", "gone", "low"])
    }

    func testSetTeachingConceptStale() throws {
        let (db, repoId, _, _, _) = try seeded()
        let store = Store(db)
        try store.insertTeachingConcepts([
            TeachingConceptRecord(id: "k1", repositoryId: repoId, kind: "claim",
                                  subjectLabel: "X", createdAt: "t0")
        ])
        try store.setTeachingConceptStale(id: "k1", stale: true)
        XCTAssertTrue(try XCTUnwrap(store.teachingConcept(id: "k1")).stale)
        XCTAssertEqual(try store.teachingConcepts(repositoryId: repoId).count, 0)
        try store.setTeachingConceptStale(id: "k1", stale: false)
        XCTAssertEqual(try store.teachingConcepts(repositoryId: repoId).count, 1)
    }

    func testDeletingSourceComponentSetsConceptFKNullNotCascade() throws {
        // Docs/17 §5 / schema comment: a re-analysis drops the old run's components, but the
        // derived concept must survive (M1 re-marks it stale, it isn't deleted).
        let (db, repoId, _, compId, claimId) = try seeded()
        let store = Store(db)
        try store.insertTeachingConcepts([
            TeachingConceptRecord(
                id: "k1", repositoryId: repoId, kind: "component", subjectLabel: "Routing",
                sourceComponentId: compId, sourceClaimId: claimId, createdAt: "t0"
            )
        ])
        try db.dbQueue.write { dbc in
            try dbc.execute(sql: "DELETE FROM components WHERE id = ?", arguments: [compId])
        }
        let fetched = try XCTUnwrap(try store.teachingConcept(id: "k1"))
        XCTAssertNil(fetched.sourceComponentId)              // SET NULL, not cascade
        XCTAssertEqual(fetched.sourceClaimId, claimId)        // claim row untouched, stays linked
        XCTAssertEqual(fetched.subjectLabel, "Routing")       // the concept itself survives
        XCTAssertEqual(try store.teachingConcepts(repositoryId: repoId).count, 1)
    }

    func testQuestionAndRubricRoundTripAndOrdering() throws {
        let (db, repoId, _, compId, claimId) = try seeded()
        let store = Store(db)
        let ids = try seedConceptQuestion(
            store, repoId: repoId, componentId: compId, claimId: claimId, conceptId: "k1")

        let q = try XCTUnwrap(try store.teachingQuestion(id: ids.questionId))
        XCTAssertTrue(q.verified)
        XCTAssertEqual(q.generatedBy, "local")
        XCTAssertEqual(q.referenceAnchors, ["starlette/routing.py::Router.app"])

        XCTAssertEqual(try store.teachingQuestions(conceptId: "k1").map(\.id), ["q1"])

        let criteria = try store.teachingRubricCriteria(questionId: "q1")
        XCTAssertEqual(criteria.map(\.ordinal), [0, 1])
        XCTAssertEqual(criteria.map(\.kind), ["required", "anti"])
    }

    func testUnverifiedQuestionHiddenByDefault() throws {
        let (db, repoId, _, _, _) = try seeded()
        let store = Store(db)
        try store.insertTeachingConcepts([
            TeachingConceptRecord(id: "k1", repositoryId: repoId, kind: "claim",
                                  subjectLabel: "X", createdAt: "t0")
        ])
        try store.insertTeachingQuestion(
            TeachingQuestionRecord(
                id: "qbad", conceptId: "k1", difficultyBand: 1, explain: "e", prompt: "p",
                referenceAnswer: "a", generatedBy: "local", verified: false, createdAt: "t0"
            ))
        XCTAssertEqual(try store.teachingQuestions(conceptId: "k1").count, 0)
        XCTAssertEqual(try store.teachingQuestions(conceptId: "k1", verifiedOnly: false).count, 1)
    }

    func testAttemptAndCriterionResultsRoundTrip() throws {
        let (db, repoId, _, compId, claimId) = try seeded()
        let store = Store(db)
        let ids = try seedConceptQuestion(
            store, repoId: repoId, componentId: compId, claimId: claimId, conceptId: "k1")

        try store.insertTeachingAttempt(
            TeachingAttemptRecord(
                id: "a1", questionId: ids.questionId, answerText: "Routes are tried in order.",
                score: 1.0, verdictTier: TeachingVerdictTier.solid.rawValue,
                modelUsed: "qwen3-8b-4bit", createdAt: "t1"
            ))
        try store.insertTeachingCriterionResults([
            TeachingCriterionResultRecord(
                id: "r1", attemptId: "a1", criterionId: ids.requiredCriterionId, met: true,
                confidence: GraderConfidence.high.rawValue,
                evidenceQuote: "tried in order", note: "explicit", voteDetail: "[true,true,true]"
            ),
            TeachingCriterionResultRecord(
                id: "r2", attemptId: "a1", criterionId: ids.antiCriterionId, met: false,
                confidence: GraderConfidence.high.rawValue
            )
        ])

        let attempt = try XCTUnwrap(try store.teachingAttempt(id: "a1"))
        XCTAssertEqual(attempt.verdictTier, "solid")
        XCTAssertFalse(attempt.disputed)

        let results = try store.teachingCriterionResults(attemptId: "a1")
        XCTAssertEqual(Set(results.map(\.id)), ["r1", "r2"])
        let r1 = try XCTUnwrap(results.first { $0.id == "r1" })
        XCTAssertTrue(r1.met)
        XCTAssertEqual(r1.voteDetail, "[true,true,true]")
        let r2 = try XCTUnwrap(results.first { $0.id == "r2" })
        XCTAssertEqual(r2.evidenceQuote, "")  // column default
    }

    func testKnowledgeStateDefaultsAndUpdate() throws {
        let (db, repoId, _, _, _) = try seeded()
        let store = Store(db)
        try store.insertTeachingConcepts([
            TeachingConceptRecord(id: "k1", repositoryId: repoId, kind: "claim",
                                  subjectLabel: "X", createdAt: "t0")
        ])
        try store.insertKnowledgeState(
            KnowledgeStateRecord(id: "ks1", conceptId: "k1", firstSeenAt: "t0", lastAssessedAt: "t0"))

        var ks = try XCTUnwrap(try store.knowledgeState(conceptId: "k1"))
        XCTAssertEqual(ks.developerId, "local")
        XCTAssertEqual(ks.pMastered, 0.15, accuracy: 1e-9)
        XCTAssertEqual(ks.confidenceBand, "new")
        XCTAssertEqual(ks.attemptsCount, 0)

        ks.pMastered = 0.72
        ks.attemptsCount = 3
        ks.confidenceBand = KnowledgeConfidenceBand.developing.rawValue
        ks.lastVerdict = TeachingVerdictTier.partial.rawValue
        ks.lastAssessedAt = "t5"
        try store.updateKnowledgeState(ks)

        let reread = try XCTUnwrap(try store.knowledgeState(conceptId: "k1"))
        XCTAssertEqual(reread.pMastered, 0.72, accuracy: 1e-9)
        XCTAssertEqual(reread.confidenceBand, "developing")
        XCTAssertEqual(reread.lastVerdict, "partial")
    }

    func testKnowledgeStateUniquePerDeveloperConcept() throws {
        let (db, repoId, _, _, _) = try seeded()
        let store = Store(db)
        try store.insertTeachingConcepts([
            TeachingConceptRecord(id: "k1", repositoryId: repoId, kind: "claim",
                                  subjectLabel: "X", createdAt: "t0")
        ])
        try store.insertKnowledgeState(
            KnowledgeStateRecord(id: "ks1", conceptId: "k1", firstSeenAt: "t0", lastAssessedAt: "t0"))
        XCTAssertThrowsError(
            try store.insertKnowledgeState(
                KnowledgeStateRecord(
                    id: "ks2", conceptId: "k1", firstSeenAt: "t0", lastAssessedAt: "t0")))
    }

    func testMisconceptionLifecycleAndOpenFilter() throws {
        let (db, repoId, _, compId, claimId) = try seeded()
        let store = Store(db)
        let ids = try seedConceptQuestion(
            store, repoId: repoId, componentId: compId, claimId: claimId, conceptId: "k1")
        try store.insertTeachingAttempt(
            TeachingAttemptRecord(id: "a1", questionId: ids.questionId, answerText: "wrong",
                                  score: 0.2, verdictTier: "off-track", createdAt: "t1"))
        try store.insertKnowledgeState(
            KnowledgeStateRecord(id: "ks1", conceptId: "k1", firstSeenAt: "t0", lastAssessedAt: "t0"))
        try store.insertTeachingMisconception(
            TeachingMisconceptionRecord(
                id: "m1", knowledgeStateId: "ks1", criterionId: ids.antiCriterionId,
                attemptId: "a1", statement: "Thinks routes match by specificity.", detectedAt: "t1"))

        XCTAssertEqual(try store.teachingMisconceptions(knowledgeStateId: "ks1", openOnly: true).count, 1)
        try store.setTeachingMisconceptionCleared(id: "m1", clearedAt: "t9")
        XCTAssertEqual(try store.teachingMisconceptions(knowledgeStateId: "ks1", openOnly: true).count, 0)
        XCTAssertEqual(try store.teachingMisconceptions(knowledgeStateId: "ks1").count, 1)
    }

    func testDeletingConceptCascadesEntireTeachingSubtree() throws {
        let (db, repoId, _, compId, claimId) = try seeded()
        let store = Store(db)
        let ids = try seedConceptQuestion(
            store, repoId: repoId, componentId: compId, claimId: claimId, conceptId: "k1")
        try store.insertTeachingAttempt(
            TeachingAttemptRecord(id: "a1", questionId: ids.questionId, answerText: "x", score: 1,
                                  verdictTier: "solid", createdAt: "t1"))
        try store.insertTeachingCriterionResults([
            TeachingCriterionResultRecord(id: "r1", attemptId: "a1",
                                          criterionId: ids.requiredCriterionId, met: true,
                                          confidence: "high")
        ])
        try store.insertKnowledgeState(
            KnowledgeStateRecord(id: "ks1", conceptId: "k1", firstSeenAt: "t0", lastAssessedAt: "t0"))
        try store.insertTeachingMisconception(
            TeachingMisconceptionRecord(id: "m1", knowledgeStateId: "ks1",
                                        criterionId: ids.antiCriterionId, attemptId: "a1",
                                        statement: "s", detectedAt: "t1"))

        try db.dbQueue.write { dbc in
            try dbc.execute(sql: "DELETE FROM teaching_concepts WHERE id = ?", arguments: ["k1"])
        }
        try db.dbQueue.read { dbc in
            XCTAssertEqual(try TeachingQuestionRecord.fetchCount(dbc), 0)
            XCTAssertEqual(try TeachingRubricCriterionRecord.fetchCount(dbc), 0)
            XCTAssertEqual(try TeachingAttemptRecord.fetchCount(dbc), 0)
            XCTAssertEqual(try TeachingCriterionResultRecord.fetchCount(dbc), 0)
            XCTAssertEqual(try KnowledgeStateRecord.fetchCount(dbc), 0)
            XCTAssertEqual(try TeachingMisconceptionRecord.fetchCount(dbc), 0)
        }
    }

    func testDeletingRepositoryCascadesTeachingConcepts() throws {
        let (db, repoId, _, _, _) = try seeded()
        let store = Store(db)
        try store.insertTeachingConcepts([
            TeachingConceptRecord(id: "k1", repositoryId: repoId, kind: "claim",
                                  subjectLabel: "X", createdAt: "t0")
        ])
        try db.dbQueue.write { dbc in
            try dbc.execute(sql: "DELETE FROM repositories WHERE id = ?", arguments: [repoId])
        }
        try db.dbQueue.read { dbc in
            XCTAssertEqual(try TeachingConceptRecord.fetchCount(dbc), 0)
        }
    }
}
