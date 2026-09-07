import XCTest

@testable import Orion
import OrionCodeIntel

/// End-to-end: a real `AnalysisPipeline` run (so real anchors exist to cite) feeding a real
/// `SemanticImporter.ingest` call, with only the `claude` CLI itself stubbed out (no network, no
/// real API cost) -- the same posture `AnalysisRunnerTests` established for Phase 1's pipeline.
final class SemanticInvestigationRunnerTests: XCTestCase {
    private func makeAnalyzedFixtureRepo() throws -> (repoRoot: URL, outputDirectory: URL) {
        let repoRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("SemanticInvestigationRunnerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: repoRoot, withIntermediateDirectories: true)
        try "def foo():\n    pass\n".write(
            to: repoRoot.appendingPathComponent("a.py"), atomically: true, encoding: .utf8)

        let outputDirectory = RepositorySession.outputDirectory(forRepoRoot: repoRoot)
        try FileManager.default.createDirectory(
            at: outputDirectory, withIntermediateDirectories: true)
        let database = try OrionDatabase(
            path: outputDirectory.appendingPathComponent("orion.db").path)
        _ = try AnalysisPipeline(database: database).run(
            AnalysisInput(repoPath: repoRoot, outputDirectory: outputDirectory, resolve: false))
        return (repoRoot, outputDirectory)
    }

    private func makeStubClaude(_ script: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SemanticInvestigationRunnerTests-stub-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let scriptURL = directory.appendingPathComponent("claude")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        return scriptURL
    }

    func testRunIngestsAValidCandidateAndReachesCompleted() async throws {
        let (repoRoot, outputDirectory) = try makeAnalyzedFixtureRepo()
        // `a.py::foo` is the real anchor for the fixture's one function -- evidence validation
        // (Docs/11 step 2) resolves it against the real Store, not a mock.
        let stub = try makeStubClaude(
            """
            #!/bin/sh
            cat <<'JSON'
            {
              "structured_output": {
                "schema_version": "phase2.v1",
                "components": [{"name": "Core", "description": "The one function.", "members": ["a.py::foo"]}],
                "component_relationships": [],
                "claims": [{"claim_type": "INTERPRETATION", "statement": "foo is a no-op.", "evidence": ["a.py::foo"], "confidence": "high"}],
                "uncertainties": []
              },
              "session_id": "sess-1",
              "num_turns": 5,
              "total_cost_usd": 0.34,
              "duration_ms": 12000,
              "is_error": false
            }
            JSON
            """)
        let session = SemanticInvestigationSession()

        await SemanticInvestigationRunner.run(
            repoRoot: repoRoot, outputDirectory: outputDirectory, session: session,
            maxBudgetUsd: 1.0, timeoutSeconds: 30, claudeBinary: stub.path)

        guard case .completed(let summary) = session.state else {
            return XCTFail("expected .completed, got \(session.state)")
        }
        XCTAssertEqual(summary.componentCount, 1)
        XCTAssertEqual(summary.droppedComponentCount, 0)
        XCTAssertEqual(summary.claimCount, 1)
        XCTAssertEqual(summary.contradictedClaimCount, 0)
        XCTAssertEqual(summary.totalCostUsd, 0.34)
        XCTAssertEqual(summary.numTurns, 5)
        // A real investigations row was persisted -- confirm by reading it back through
        // CodebaseModelStore (Docs/13 M3's other deliverable), not just trusting the summary.
        let modelStore = CodebaseModelStore(outputDirectory: outputDirectory)
        let run = try modelStore.latestRun()
        let investigation = try modelStore.latestInvestigation(runId: XCTUnwrap(run).id)
        XCTAssertEqual(investigation?.outcome, summary.outcome)
    }

    func testRunSurfacesUnresolvableAnchorAsDroppedNotCrashed() async throws {
        let (repoRoot, outputDirectory) = try makeAnalyzedFixtureRepo()
        let stub = try makeStubClaude(
            """
            #!/bin/sh
            cat <<'JSON'
            {
              "structured_output": {
                "schema_version": "phase2.v1",
                "components": [{"name": "Bogus", "members": ["a.py::doesNotExist"]}],
                "component_relationships": [],
                "claims": [],
                "uncertainties": ["Nothing was grounded."]
              },
              "is_error": false
            }
            JSON
            """)
        let session = SemanticInvestigationSession()

        await SemanticInvestigationRunner.run(
            repoRoot: repoRoot, outputDirectory: outputDirectory, session: session,
            maxBudgetUsd: 1.0, timeoutSeconds: 30, claudeBinary: stub.path)

        guard case .completed(let summary) = session.state else {
            return XCTFail("expected .completed (a dropped component is not a crash), got \(session.state)")
        }
        XCTAssertEqual(summary.componentCount, 0)
        XCTAssertEqual(summary.droppedComponentCount, 1)
    }

    func testRunReachesFailedWhenClaudeExitsWithError() async throws {
        let (repoRoot, outputDirectory) = try makeAnalyzedFixtureRepo()
        let stub = try makeStubClaude(
            """
            #!/bin/sh
            cat <<'JSON'
            {"is_error": true, "errors": ["Reached maximum budget ($1.00)"]}
            JSON
            """)
        let session = SemanticInvestigationSession()

        await SemanticInvestigationRunner.run(
            repoRoot: repoRoot, outputDirectory: outputDirectory, session: session,
            maxBudgetUsd: 1.0, timeoutSeconds: 30, claudeBinary: stub.path)

        guard case .failed(let message) = session.state else {
            return XCTFail("expected .failed, got \(session.state)")
        }
        XCTAssertTrue(message.contains("maximum budget"))
    }

    func testRunReachesFailedWhenNoAnalyzedRunExists() async throws {
        let repoRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("SemanticInvestigationRunnerTests-unanalyzed-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: repoRoot, withIntermediateDirectories: true)
        let outputDirectory = RepositorySession.outputDirectory(forRepoRoot: repoRoot)
        // No `.orion/orion.db` created -- this repo was never analyzed.
        let stub = try makeStubClaude(
            """
            #!/bin/sh
            cat <<'JSON'
            {"structured_output": {"schema_version": "phase2.v1", "components": [], "component_relationships": [], "claims": [], "uncertainties": []}, "is_error": false}
            JSON
            """)
        let session = SemanticInvestigationSession()

        await SemanticInvestigationRunner.run(
            repoRoot: repoRoot, outputDirectory: outputDirectory, session: session,
            maxBudgetUsd: 1.0, timeoutSeconds: 30, claudeBinary: stub.path)

        guard case .failed = session.state else {
            return XCTFail("expected .failed, got \(session.state)")
        }
    }
}
