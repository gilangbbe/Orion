import XCTest
@testable import OrionCodeIntel
@testable import OrionCore

/// Docs/17 M2: `TeachingQuestionVerifier` against fixture data — real `Store`, hand-built rows,
/// no model. This is the load-bearing "make the LLM's output safe before it's shown" gate, so it
/// gets the bulk of M2's test coverage.
final class TeachingQuestionVerifierTests: XCTestCase {

    private func seed() throws -> (store: Store, run: AnalysisRunRecord, concept: TeachingConceptRecord) {
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
            try FileRecord(
                id: "file1", repositoryId: "repo", commitHash: "c0ffee", runId: "run",
                path: "m/a.py", language: "python", modulePath: "m.a", sha256: "x",
                byteSize: 10, lineCount: 10, isTest: false, isPackageInit: false, parseOk: true
            ).insert(dbc)
            for (id, anchor) in [("s1", "m/a.py::Router"), ("s2", "m/a.py::Route"),
                                 ("s3", "m/a.py::Middleware")] {
                try SymbolRecord(
                    id: id, repositoryId: "repo", commitHash: "c0ffee", runId: "run", fileId: "file1",
                    componentId: nil, parentSymbolId: nil, name: id, qualifiedName: id, anchor: anchor,
                    kind: "class", startLine: 1, startCol: 0, endLine: 2, endCol: 0, startByte: 0,
                    endByte: 10, signature: "class \(id)", docstring: nil, decorators: [],
                    visibility: "public", isExported: true, redirectsTo: nil, epistemicType: "FACT"
                ).insert(dbc)
            }
        }
        let run = try XCTUnwrap(store.run(id: "run"))
        try store.insertTeachingConcepts([TeachingConceptRecord(
            id: "k1", repositoryId: "repo", kind: "component", subjectLabel: "Routing",
            evidenceAnchors: ["m/a.py::Router", "m/a.py::Route"], centrality: 0.5,
            difficultyBand: 1, createdAt: "t0")])
        let concept = try XCTUnwrap(store.teachingConcept(id: "k1"))
        return (store, run, concept)
    }

    private func candidate(
        schemaVersion: String = TeachingSchema.currentVersion,
        conceptId: String = "k1",
        band: Int = 1,
        referenceAnswer: String = "Router iterates its Route list in declaration order and dispatches to the first match.",
        referenceAnchors: [String] = ["m/a.py::Router", "m/a.py::Route"],
        rubric: [RubricCriterionInput] = [
            RubricCriterionInput(kind: "required", text: "States routes are checked in declaration order.",
                                 evidence: ["m/a.py::Router"]),
            RubricCriterionInput(kind: "required", text: "Identifies Route as the unit Router matches against.",
                                 evidence: ["m/a.py::Route"]),
            RubricCriterionInput(kind: "bonus", text: "Mentions first-match-wins short-circuiting.",
                                 evidence: ["m/a.py::Router"]),
        ],
        antiCriteria: [AntiCriterionInput] = [
            AntiCriterionInput(text: "Claims routes are matched by longest-prefix / specificity.",
                               evidence: ["m/a.py::Router"]),
        ],
        transfer: String? = "What happens when two routes match the same path?"
    ) -> TeachingQuestionCandidate {
        TeachingQuestionCandidate(
            schemaVersion: schemaVersion, conceptId: conceptId, difficultyBand: band,
            explain: "Router is the dispatch entry point for HTTP routing.",
            question: "How does Router decide which Route handles a request?",
            referenceAnswer: referenceAnswer, referenceAnchors: referenceAnchors,
            rubric: rubric, antiCriteria: antiCriteria, transferProblem: transfer)
    }

    private func verify(
        _ c: TeachingQuestionCandidate, _ f: (store: Store, run: AnalysisRunRecord, concept: TeachingConceptRecord)
    ) throws -> TeachingQuestionVerifier.Outcome {
        try TeachingQuestionVerifier.verifyAndPersist(
            candidate: c, concept: f.concept, store: f.store, run: f.run, generatedBy: .local, now: "tX")
    }

    func testValidCandidatePersists() throws {
        let f = try seed()
        guard case .persisted(let qid, let dropped) = try verify(candidate(), f) else {
            return XCTFail("expected .persisted")
        }
        XCTAssertEqual(dropped, 0)
        let q = try XCTUnwrap(f.store.teachingQuestion(id: qid))
        XCTAssertTrue(q.verified)
        XCTAssertEqual(q.generatedBy, "local")
        XCTAssertNil(q.investigationId)   // M2: no investigations row (documented deviation)
        XCTAssertEqual(q.referenceAnchors, ["m/a.py::Route", "m/a.py::Router"])   // sorted
        let criteria = try f.store.teachingRubricCriteria(questionId: qid)
        XCTAssertEqual(criteria.map(\.kind), ["required", "required", "bonus", "anti"])
        XCTAssertEqual(criteria.map(\.ordinal), [0, 1, 2, 3])
    }

    func testSchemaVersionMismatchRejected() throws {
        let f = try seed()
        guard case .rejected(let reasons) = try verify(candidate(schemaVersion: "phase6.v9"), f) else {
            return XCTFail("expected .rejected")
        }
        XCTAssertTrue(reasons.contains { $0.code == TeachingQuestionVerifier.codeSchemaInvalid })
        XCTAssertNil(try f.store.teachingQuestion(id: "nope"))
        XCTAssertEqual(try f.store.teachingQuestions(conceptId: "k1", verifiedOnly: false).count, 0)
    }

    func testConceptIdMismatchRejected() throws {
        let f = try seed()
        guard case .rejected = try verify(candidate(conceptId: "someone-else"), f) else {
            return XCTFail("expected .rejected")
        }
    }

    func testBandOutOfRangeRejected() throws {
        let f = try seed()
        guard case .rejected = try verify(candidate(band: 4), f) else { return XCTFail() }
    }

    func testShortReferenceAnswerRejected() throws {
        let f = try seed()
        guard case .rejected(let reasons) = try verify(candidate(referenceAnswer: "Too short."), f) else {
            return XCTFail()
        }
        XCTAssertTrue(reasons.contains { $0.message.contains("reference_answer") })
    }

    func testNoRequiredCriterionRejected() throws {
        let f = try seed()
        let c = candidate(rubric: [
            RubricCriterionInput(kind: "bonus", text: "A nice-to-have point here.", evidence: ["m/a.py::Router"])
        ])
        guard case .rejected = try verify(c, f) else { return XCTFail() }
    }

    func testRubricKindOutsideRequiredOrBonusRejected() throws {
        let f = try seed()
        let c = candidate(rubric: [
            RubricCriterionInput(kind: "anti", text: "This belongs in anti_criteria not rubric.",
                                 evidence: ["m/a.py::Router"]),
            RubricCriterionInput(kind: "required", text: "A real required criterion here.",
                                 evidence: ["m/a.py::Router"]),
        ])
        guard case .rejected(let reasons) = try verify(c, f) else { return XCTFail() }
        XCTAssertTrue(reasons.contains { $0.code == TeachingQuestionVerifier.codeSchemaInvalid })
    }

    func testRequiredCriterionWithUnresolvableAnchorRejected() throws {
        let f = try seed()
        let c = candidate(rubric: [
            RubricCriterionInput(kind: "required", text: "Cites a symbol that does not exist.",
                                 evidence: ["m/a.py::GhostSymbol"]),
        ])
        guard case .rejected(let reasons) = try verify(c, f) else { return XCTFail() }
        XCTAssertTrue(reasons.contains { $0.code == TeachingQuestionVerifier.codeAnchorUnresolved && $0.fatal })
    }

    func testUnresolvableReferenceAnchorRejected() throws {
        let f = try seed()
        guard case .rejected(let reasons) = try verify(
            candidate(referenceAnchors: ["m/a.py::Router", "m/a.py::Nope"]), f)
        else { return XCTFail() }
        XCTAssertTrue(reasons.contains { $0.code == TeachingQuestionVerifier.codeAnchorUnresolved })
    }

    func testBonusAndAntiCriteriaWithBadAnchorsAreDroppedNotFatal() throws {
        let f = try seed()
        let c = candidate(
            rubric: [
                RubricCriterionInput(kind: "required", text: "A solid required criterion here.",
                                     evidence: ["m/a.py::Router"]),
                RubricCriterionInput(kind: "bonus", text: "Bonus that cites a ghost symbol.",
                                     evidence: ["m/a.py::Ghost"]),
            ],
            antiCriteria: [
                AntiCriterionInput(text: "Anti that cites a ghost symbol.", evidence: ["m/a.py::AlsoGhost"]),
            ])
        guard case .persisted(let qid, let dropped) = try verify(c, f) else { return XCTFail() }
        XCTAssertEqual(dropped, 2)
        XCTAssertEqual(try f.store.teachingRubricCriteria(questionId: qid).map(\.kind), ["required"])
        let diags = try f.store.diagnostics(runId: "run")
        XCTAssertTrue(diags.contains {
            $0.stage == "teaching_generate" && $0.code == TeachingQuestionVerifier.codeCriterionDropped
                && $0.severity == "warning"
        })
    }

    func testReferenceMatchingContradictedClaimRejected() throws {
        let f = try seed()
        try f.store.insertInvestigation(InvestigationRecord(
            id: "inv", repositoryId: "repo", commitHash: "c0ffee", runId: "run",
            question: "phase2_semantic_grouping", complexity: "high", outcome: "verified", createdAt: "t0"))
        try f.store.insertClaims([ClaimRecord(
            id: "cl1", repositoryId: "repo", commitHash: "c0ffee", runId: "run", investigationId: "inv",
            subjectRef: "m/a.py::Router", predicate: nil, objectRef: nil,
            statement: "Router matches by specificity.", claimType: EpistemicType.contradicted.rawValue,
            confidence: 0.3, status: "active", createdBy: "claude_code")])
        try f.store.insertEvidence([
            EvidenceRecord(id: "e1", claimId: "cl1", fileId: "file1", symbolId: "s1",
                           anchor: "m/a.py::Router", startLine: nil, endLine: nil, evidenceType: "source"),
            EvidenceRecord(id: "e2", claimId: "cl1", fileId: "file1", symbolId: "s2",
                           anchor: "m/a.py::Route", startLine: nil, endLine: nil, evidenceType: "source"),
        ])
        guard case .rejected(let reasons) = try verify(candidate(), f) else { return XCTFail() }
        let reason = try XCTUnwrap(reasons.first { $0.code == TeachingQuestionVerifier.codeReferenceContradicted })
        // Fed back to the drafter on its retry (Docs/19 M7): which claim to stay off.
        XCTAssertTrue(reason.message.contains("Router matches by specificity."), reason.message)
        XCTAssertTrue(reason.message.contains("a different part of the concept than m/a.py::Route, m/a.py::Router"), reason.message)
    }

    func testReferenceMatchingNonContradictedClaimPasses() throws {
        let f = try seed()
        try f.store.insertInvestigation(InvestigationRecord(
            id: "inv", repositoryId: "repo", commitHash: "c0ffee", runId: "run",
            question: "phase2_semantic_grouping", complexity: "high", outcome: "verified", createdAt: "t0"))
        try f.store.insertClaims([ClaimRecord(
            id: "cl1", repositoryId: "repo", commitHash: "c0ffee", runId: "run", investigationId: "inv",
            subjectRef: "m/a.py::Router", predicate: nil, objectRef: nil,
            statement: "Router iterates routes in order.", claimType: "INTERPRETATION",
            confidence: 0.8, status: "active", createdBy: "claude_code")])
        try f.store.insertEvidence([
            EvidenceRecord(id: "e1", claimId: "cl1", fileId: "file1", symbolId: "s1",
                           anchor: "m/a.py::Router", startLine: nil, endLine: nil, evidenceType: "source"),
            EvidenceRecord(id: "e2", claimId: "cl1", fileId: "file1", symbolId: "s2",
                           anchor: "m/a.py::Route", startLine: nil, endLine: nil, evidenceType: "source"),
        ])
        guard case .persisted = try verify(candidate(), f) else { return XCTFail("should pass") }
    }

    func testRejectionPersistsErrorDiagnostic() throws {
        let f = try seed()
        _ = try verify(candidate(schemaVersion: "wrong"), f)
        let diags = try f.store.diagnostics(runId: "run")
        XCTAssertTrue(diags.contains {
            $0.stage == "teaching_generate" && $0.code == TeachingQuestionVerifier.codeSchemaInvalid
                && $0.severity == "error"
        })
    }
}
