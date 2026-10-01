import FoundationModels
import XCTest
@testable import OrionCodeIntel
@testable import OrionCore
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

    // MARK: - Guided drafter (Docs/19 M7)

    /// What the guided drafter was asked, per call.
    private final class GuidedCalls: @unchecked Sendable {
        var prompts: [String] = []
        var schemas: [String] = []
        var instructions: [String] = []
    }

    /// The guided shape -- what the system model would generate into the drafter's schema.
    private let guidedReply = #"""
        {"explain": "Router is the routing entry point.", "question": "How does Router pick a Route?",
         "referenceAnswer": "Router iterates its Route list in declaration order and dispatches to the first match.",
         "referenceAnchors": ["m/a.py::Router", "m/a.py::Route"],
         "required": [{"text": "States routes are checked in declaration order.", "evidence": ["m/a.py::Router"]},
                      {"text": "Identifies Route as the matched unit.", "evidence": ["m/a.py::Route"]}],
         "bonus": [],
         "wrong": [{"text": "Claims routes match by longest-prefix specificity.", "evidence": ["m/a.py::Router"]}],
         "transferProblem": "What if two routes match the same path?"}
        """#

    private func guidedDrafter(
        _ calls: GuidedCalls, reply: String? = nil, budget: Int? = nil,
        countTokens: GuidedTeachingDrafter.CountTokens? = nil, failFirst: Bool = false
    ) -> GuidedTeachingDrafter {
        let reply = reply ?? guidedReply
        return GuidedTeachingDrafter(source: .device, inputBudget: budget, countTokens: countTokens) { instructions, prompt, schema in
            calls.instructions.append(instructions)
            calls.prompts.append(prompt)
            calls.schemas.append(String(decoding: try JSONEncoder().encode(schema), as: UTF8.self))
            if failFirst, calls.prompts.count == 1 {
                throw LanguageModelError.contextSizeExceeded(.init(contextSize: 4096, tokenCount: 5000, debugDescription: "x"))
            }
            return try GeneratedContent(json: reply)
        }
    }

    func testGuidedDrafterPersistsAVerifiedDeviceQuestion() async throws {
        let f = try seed()
        let calls = GuidedCalls()
        let result = try await gen(f, guidedDrafter(calls)).generate(concept: f.concept)
        guard case .generated(let qid, let band, _, let attempts) = result else { return XCTFail("got \(result)") }
        XCTAssertEqual([band, attempts], [1, 1])

        let question = try XCTUnwrap(f.store.teachingQuestion(id: qid))
        XCTAssertEqual(question.generatedBy, TeachingQuestionSource.device.rawValue, "carried across re-imports (M3)")
        let kinds = try f.store.teachingRubricCriteria(questionId: qid).map(\.kind)
        XCTAssertEqual(kinds, ["required", "required", "anti"])

        // The prompt is the task and the grounding; the schema carries the shape.
        let prompt = try XCTUnwrap(calls.prompts.first)
        XCTAssertTrue(prompt.contains("Concept (component): Routing"), prompt)
        XCTAssertTrue(prompt.contains("m/a.py::Router — class s1"), prompt)
        XCTAssertFalse(prompt.contains("schema_version"), "no JSON shape spelled out in prose")
    }

    /// Anchors are an enum of the concept's own anchors: the model can't produce one that the
    /// verifier would reject as unresolvable.
    func testGuidedDrafterSchemaOnlyAllowsTheConceptsAnchors() async throws {
        let f = try seed()
        let calls = GuidedCalls()
        _ = try await gen(f, guidedDrafter(calls)).generate(concept: f.concept)
        let schema = try XCTUnwrap(calls.schemas.first)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(schema.utf8)) as? [String: Any])
        // Every anchor field -- reference anchors and each point's evidence -- is that enum.
        var enums: [[String]] = []
        func walk(_ value: Any) {
            if let dict = value as? [String: Any] {
                if let values = dict["enum"] as? [String] { enums.append(values) }
                dict.values.forEach(walk)
            } else if let array = value as? [Any] {
                array.forEach(walk)
            }
        }
        walk(object)
        XCTAssertEqual(enums.count, 2, schema)
        for values in enums { XCTAssertEqual(Set(values), ["m/a.py::Router", "m/a.py::Route"], schema) }
        XCTAssertEqual(
            object["x-order"] as? [String],
            ["explain", "question", "referenceAnswer", "referenceAnchors", "required", "bonus", "wrong", "transferProblem"])
    }

    func testGuidedDrafterTrimsGroundingToFitTheBudget() async throws {
        let anchors = (1...10).map { "m/a.py::C\($0)" }
        let inputs = TeachingPromptInputs(
            conceptId: "k1", conceptKind: "component", conceptLabel: "Routing", band: 1,
            evidenceLines: anchors.map { "\($0) — class" }, evidenceAnchors: anchors)
        let calls = GuidedCalls()
        // One token per grounding line: the budget fits four.
        let drafter = guidedDrafter(calls, budget: 4) { _, prompt, _ in
            prompt.components(separatedBy: "\n- ").count - 1
        }
        _ = try await drafter.draft(inputs: inputs)
        let lines = try XCTUnwrap(calls.prompts.first).components(separatedBy: "\n- ").count - 1
        XCTAssertLessThanOrEqual(lines, 4)
        XCTAssertGreaterThanOrEqual(lines, GuidedTeachingDrafter.minAnchors)
    }

    func testGuidedDrafterRetriesOnceWithLessGroundingAfterAnOverflow() async throws {
        let anchors = (1...8).map { "m/a.py::C\($0)" }
        let inputs = TeachingPromptInputs(
            conceptId: "k1", conceptKind: "component", conceptLabel: "Routing", band: 1,
            evidenceLines: anchors.map { "\($0) — class" }, evidenceAnchors: anchors)
        let calls = GuidedCalls()
        _ = try await guidedDrafter(calls, failFirst: true).draft(inputs: inputs)
        XCTAssertEqual(calls.prompts.count, 2)
        func lines(_ p: String) -> Int { p.components(separatedBy: "\n- ").count - 1 }
        XCTAssertEqual(lines(calls.prompts[0]), 8)
        XCTAssertEqual(lines(calls.prompts[1]), 4)
    }

    func testGuidedDrafterTakesBandAndConceptFromTheRequestNotTheModel() throws {
        let inputs = TeachingPromptInputs(
            conceptId: "k9", conceptKind: "claim", conceptLabel: "x", band: 2, evidenceLines: [], evidenceAnchors: [])
        let json = try GuidedTeachingDrafter.candidateJSON(from: GeneratedContent(json: guidedReply), inputs: inputs)
        let candidate = try JSONDecoder().decode(TeachingQuestionCandidate.self, from: Data(json.utf8))
        XCTAssertEqual(candidate.conceptId, "k9")
        XCTAssertEqual(candidate.difficultyBand, 2)
        XCTAssertEqual(candidate.schemaVersion, TeachingSchema.currentVersion)
        XCTAssertEqual(candidate.rubric.map(\.kind), ["required", "required"])
        XCTAssertEqual(candidate.antiCriteria.count, 1)
    }

    func testGroundingPutsClassesBeforeMethodsBeforeModules() {
        let anchors = ["m/a.py", "m/a.py::Router.add", "m/a.py::Router", "m/b.py::handle"]
        let inputs = TeachingPromptInputs(
            conceptId: "k", conceptKind: "component", conceptLabel: "x", band: 1,
            evidenceLines: anchors, evidenceAnchors: anchors)
        XCTAssertEqual(
            GuidedTeachingDrafter.prioritized(inputs).map(\.anchor),
            ["m/a.py::Router", "m/b.py::handle", "m/a.py::Router.add", "m/a.py"])
    }

    /// The live Mac run's concept "Routing & Endpoint Dispatch" got a question about convertors,
    /// whose classes sort first by name (Docs/19 M7).
    func testGroundingPrefersSymbolsNamedLikeTheConcept() {
        let anchors = [
            "s/convertors.py::Convertor", "s/convertors.py::FloatConvertor", "s/endpoints.py::HTTPEndpoint",
            "s/routing.py::Router", "s/routing.py::Router.app",
        ]
        let inputs = TeachingPromptInputs(
            conceptId: "k", conceptKind: "component", conceptLabel: "Routing & Endpoint Dispatch", band: 1,
            evidenceLines: anchors, evidenceAnchors: anchors)
        XCTAssertEqual(
            GuidedTeachingDrafter.prioritized(inputs).map(\.anchor),
            ["s/endpoints.py::HTTPEndpoint", "s/routing.py::Router", "s/routing.py::Router.app",
             "s/convertors.py::Convertor", "s/convertors.py::FloatConvertor"])
    }

    func testTheGuidedDrafterRefusesAPlainPrompt() async {
        let drafter = guidedDrafter(GuidedCalls())
        do {
            _ = try await drafter.draft(prompt: "p", band: 1)
            XCTFail("expected needsInputs")
        } catch {}
    }

    /// One concrete task per band and kind: offered "X, or Y", the phone's model asked both
    /// (Docs/19 M7).
    func testTheDraftingTaskIsChosenInCodeNotOfferedAsAlternatives() {
        let relationship = GuidedTeachingDrafter.task(
            band: 2, kind: TeachingConceptKind.relationship.rawValue, label: "Routing → Exception Handling")
        XCTAssertTrue(relationship.contains("what Routing uses from Exception Handling"), relationship)
        let component = GuidedTeachingDrafter.task(band: 2, kind: TeachingConceptKind.component.rawValue)
        XCTAssertNotEqual(relationship, component)
        for band in 1...3 {
            for kind in TeachingConceptKind.allCases {
                XCTAssertFalse(GuidedTeachingDrafter.task(band: band, kind: kind.rawValue).contains(", or "))
            }
        }
        let inputs = TeachingPromptInputs(
            conceptId: "k", conceptKind: "component", conceptLabel: "x", band: 1, evidenceLines: [], evidenceAnchors: [])
        XCTAssertTrue(GuidedTeachingDrafter.prompt(inputs, grounding: []).contains("Ask one question, not several."))
    }

    // MARK: - Code excerpts (Docs/19 M8)

    /// On a snapshot, the drafter sees the top symbols' code, not just their signatures.
    func testTheGuidedDrafterSeesTheCitedCodeFromASnapshot() async throws {
        let f = try seed()
        try f.store.insertEvidenceSnippets([EvidenceSnippetRecord(
            filePath: "m/a.py", startLine: 1, endLine: 2, firstLine: 1, text: "class Router:\n    routes = []",
            truncated: false, fileSha256: "x")])
        let calls = GuidedCalls()
        _ = try await gen(f, guidedDrafter(calls)).generate(concept: f.concept)
        let prompt = try XCTUnwrap(calls.prompts.first)
        XCTAssertTrue(prompt.contains("Code:\n    class Router:\n        routes = []"), prompt)
    }

    func testCodeExcerptsAreDroppedBeforeSymbols() async throws {
        let anchors = (1...6).map { "m/a.py::C\($0)" }
        let inputs = TeachingPromptInputs(
            conceptId: "k1", conceptKind: "component", conceptLabel: "Routing", band: 1,
            evidenceLines: anchors.map { "\($0) — class" }, evidenceAnchors: anchors,
            codeExcerpts: Dictionary(uniqueKeysWithValues: anchors.map { ($0, "pass") }))
        let calls = GuidedCalls()
        // Fits all six symbols, but not with any code.
        let drafter = guidedDrafter(calls, budget: 6) { _, prompt, _ in
            prompt.components(separatedBy: "\n- ").count - 1 + (prompt.contains("Code:") ? 100 : 0)
        }
        _ = try await drafter.draft(inputs: inputs)
        let prompt = try XCTUnwrap(calls.prompts.first)
        XCTAssertFalse(prompt.contains("Code:"), prompt)
        XCTAssertEqual(prompt.components(separatedBy: "\n- ").count - 1, 6, "no symbol dropped while code could go")
    }

    func testAnExcerptIsTheCitedLinesCapped() {
        let slice = EvidenceSlice.Slice(
            firstLine: 10, lines: (10...40).map { "line \($0)" }, highlight: 13...35, truncated: false)
        let excerpt = TeachingQuestionGenerator.excerpt(slice).components(separatedBy: "\n")
        XCTAssertEqual(excerpt.first, "line 13")
        XCTAssertEqual(excerpt.count, TeachingQuestionGenerator.excerptLines)
    }
}
