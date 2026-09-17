import XCTest
@testable import OrionCodeIntel
@testable import OrionAgent

/// Docs/17 M2: `TeachingQuestionGenerator` orchestration (gather context -> prompt -> parse ->
/// verify -> retry-once) with a scripted drafter — no live model. The verification logic itself
/// is covered by `TeachingQuestionVerifierTests`; this file is about the loop around it.
final class TeachingQuestionGeneratorTests: XCTestCase {

    /// A drafter that replays a fixed script of raw strings, one per attempt.
    private struct ScriptedDrafter: TeachingQuestionDrafting {
        let source: TeachingQuestionSource
        let script: [String]
        final class Counter: @unchecked Sendable { var n = 0 }
        let counter = Counter()
        func draft(prompt: String, band: Int) async throws -> String {
            defer { counter.n += 1 }
            return script[min(counter.n, script.count - 1)]
        }
    }

    private func seed(conceptAnchors: [String] = ["m/a.py::Router", "m/a.py::Route"])
        throws -> (store: Store, run: AnalysisRunRecord, concept: TeachingConceptRecord)
    {
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
                id: "file1", repositoryId: "repo", commitHash: "c0ffee", runId: "run", path: "m/a.py",
                language: "python", modulePath: "m.a", sha256: "x", byteSize: 10, lineCount: 10,
                isTest: false, isPackageInit: false, parseOk: true
            ).insert(dbc)
            for (id, anchor) in [("s1", "m/a.py::Router"), ("s2", "m/a.py::Route")] {
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
            evidenceAnchors: conceptAnchors, centrality: 0.5, difficultyBand: 1, createdAt: "t0")])
        return (store, run, try XCTUnwrap(store.teachingConcept(id: "k1")))
    }

    private func validCandidateJSON(conceptId: String = "k1", band: Int = 1,
                                    requiredAnchor: String = "m/a.py::Router") -> String {
        """
        Here is the question:
        {
          "schema_version": "\(TeachingSchema.currentVersion)",
          "concept_id": "\(conceptId)",
          "difficulty_band": \(band),
          "explain": "Router is the routing entry point.",
          "question": "How does Router pick a Route?",
          "reference_answer": "Router iterates its Route list in declaration order and dispatches to the first match.",
          "reference_anchors": ["m/a.py::Router", "m/a.py::Route"],
          "rubric": [
            {"kind": "required", "text": "States routes are checked in declaration order.", "evidence": ["\(requiredAnchor)"]},
            {"kind": "required", "text": "Identifies Route as the matched unit.", "evidence": ["m/a.py::Route"]}
          ],
          "anti_criteria": [
            {"text": "Claims routes match by longest-prefix specificity.", "evidence": ["m/a.py::Router"]}
          ],
          "transfer_problem": "What if two routes match the same path?"
        }
        Thanks!
        """
    }

    private func gen(_ f: (store: Store, run: AnalysisRunRecord, concept: TeachingConceptRecord),
                     _ drafter: any TeachingQuestionDrafting) -> TeachingQuestionGenerator {
        TeachingQuestionGenerator(store: f.store, run: f.run, drafter: drafter, now: { "tX" })
    }

    func testHappyPathPersistsOnFirstAttempt() async throws {
        let f = try seed()
        let drafter = ScriptedDrafter(source: .local, script: [validCandidateJSON()])
        let result = try await gen(f, drafter).generate(concept: f.concept)
        guard case .generated(let qid, let band, let dropped, let attempts) = result else {
            return XCTFail("got \(result)")
        }
        XCTAssertEqual([band, dropped, attempts], [1, 0, 1])
        XCTAssertEqual(drafter.counter.n, 1)
        XCTAssertEqual(try f.store.teachingQuestion(id: qid)?.generatedBy, "local")
    }

    func testRetriesOnceAfterUnparsableThenSucceeds() async throws {
        let f = try seed()
        let drafter = ScriptedDrafter(source: .local, script: ["no json here", validCandidateJSON()])
        let result = try await gen(f, drafter).generate(concept: f.concept)
        guard case .generated(_, _, _, let attempts) = result else { return XCTFail("got \(result)") }
        XCTAssertEqual(attempts, 2)
    }

    func testRejectedBothAttemptsReturnsRejected() async throws {
        let f = try seed()
        let bad = validCandidateJSON(requiredAnchor: "m/a.py::GhostSymbol")
        let drafter = ScriptedDrafter(source: .local, script: [bad, bad])
        let result = try await gen(f, drafter).generate(concept: f.concept)
        guard case .rejected(let reasons, let attempts) = result else { return XCTFail("got \(result)") }
        XCTAssertEqual(attempts, 2)
        XCTAssertTrue(reasons.contains { $0.contains("unresolvable anchor") })
        XCTAssertEqual(try f.store.teachingQuestions(conceptId: "k1", verifiedOnly: false).count, 0)
    }

    func testUnparsableBothAttemptsReturnsDraftUnusable() async throws {
        let f = try seed()
        let drafter = ScriptedDrafter(source: .local, script: ["nope", "still nope"])
        let result = try await gen(f, drafter).generate(concept: f.concept)
        guard case .draftUnusable(_, let attempts) = result else { return XCTFail("got \(result)") }
        XCTAssertEqual(attempts, 2)
    }

    func testConceptWithNoResolvableAnchorsShortCircuitsBeforeDrafting() async throws {
        let f = try seed(conceptAnchors: ["m/a.py::DoesNotExist"])
        let drafter = ScriptedDrafter(source: .local, script: [validCandidateJSON()])
        let result = try await gen(f, drafter).generate(concept: f.concept)
        guard case .draftUnusable(_, let attempts) = result else { return XCTFail("got \(result)") }
        XCTAssertEqual(attempts, 0)
        XCTAssertEqual(drafter.counter.n, 0, "drafter must not be called")
    }

    func testGeneratedByReflectsClaudeDrafterSource() async throws {
        let f = try seed()
        let drafter = ScriptedDrafter(source: .claudeCode, script: [validCandidateJSON(band: 3)])
        let result = try await gen(f, drafter).generate(concept: f.concept, band: 3)
        guard case .generated(let qid, _, _, _) = result else { return XCTFail("got \(result)") }
        XCTAssertEqual(try f.store.teachingQuestion(id: qid)?.generatedBy, "claude_code")
    }

    func testExtractJSONObjectToleratesSurroundingProse() {
        XCTAssertEqual(
            TeachingQuestionGenerator.extractJSONObject("blah {\"a\": 1} trailing"),
            "{\"a\": 1}")
        XCTAssertNil(TeachingQuestionGenerator.extractJSONObject("no braces at all"))
    }
}
