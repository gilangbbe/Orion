import XCTest
@testable import OrionCodeIntel
@testable import OrionAgent

/// Docs/17 M2's "one live generation confirmed by hand". Costs a real Core AI model load (and,
/// for the Claude variant, a real paid `claude` call), so it is `XCTSkip`'d unless the matching
/// env var is set — same posture as `ClaudeCodeInvestigatorLiveTests`. Also listed in CI's
/// `--skip` set as defense in depth. Plain SwiftPM since Docs/18 M6 (no `xcodebuild`):
///
/// ```
/// ORION_TEACHING_LIVE_LOCAL=1 swift test --filter \
///   TeachingGenerationLiveTests/testLocalDrafterGeneratesAVerifiedQuestion
/// ```
final class TeachingGenerationLiveTests: XCTestCase {

    /// A tiny in-memory analyzed fixture: one file, two real-looking class symbols, one concept.
    private func fixture() throws -> (store: Store, run: AnalysisRunRecord, concept: TeachingConceptRecord) {
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
                path: "app/routing.py", language: "python", modulePath: "app.routing", sha256: "x",
                byteSize: 10, lineCount: 10, isTest: false, isPackageInit: false, parseOk: true
            ).insert(dbc)
            for (id, anchor, sig) in [
                ("s1", "app/routing.py::Router", "class Router(routes: list[Route])"),
                ("s2", "app/routing.py::Route", "class Route(path: str, endpoint: Callable)"),
            ] {
                try SymbolRecord(
                    id: id, repositoryId: "repo", commitHash: "c0ffee", runId: "run", fileId: "file1",
                    componentId: nil, parentSymbolId: nil, name: id, qualifiedName: id, anchor: anchor,
                    kind: "class", startLine: 1, startCol: 0, endLine: 2, endCol: 0, startByte: 0,
                    endByte: 10, signature: sig, docstring: nil, decorators: [], visibility: "public",
                    isExported: true, redirectsTo: nil, epistemicType: "FACT"
                ).insert(dbc)
            }
        }
        try store.insertTeachingConcepts([TeachingConceptRecord(
            id: "k1", repositoryId: "repo", kind: "component", subjectLabel: "Routing",
            evidenceAnchors: ["app/routing.py::Router", "app/routing.py::Route"], centrality: 0.8,
            difficultyBand: 1, createdAt: "t0")])
        return (store, try XCTUnwrap(store.run(id: "run")), try XCTUnwrap(store.teachingConcept(id: "k1")))
    }

    func testLocalDrafterGeneratesAVerifiedQuestion() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["ORION_TEACHING_LIVE_LOCAL"] == "1")
        let f = try fixture()
        let agent = try await LocalModelLoader.shared.model(for: .defaultCoreAI, role: .drafting)
        let drafter = LocalTeachingDrafter { prompt in
            try await agent.respond(to: prompt, instructions: LocalTeachingDrafter.systemInstruction)
        }
        let result = try await TeachingQuestionGenerator(store: f.store, run: f.run, drafter: drafter)
            .generate(concept: f.concept, band: 1)
        print("LOCAL generation result: \(result)")
        guard case .generated(let qid, _, _, _) = result else {
            return XCTFail("local model did not produce a verified question: \(result)")
        }
        let q = try XCTUnwrap(f.store.teachingQuestion(id: qid))
        XCTAssertFalse(q.prompt.isEmpty)
        XCTAssertGreaterThanOrEqual(try f.store.teachingRubricCriteria(questionId: qid).count, 1)
    }
}
