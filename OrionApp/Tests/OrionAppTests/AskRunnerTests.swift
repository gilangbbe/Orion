import XCTest

@testable import Orion
import OrionAgent
import OrionCodeIntel

/// A fixed-response `TurnGenerating` fake -- the same seam `OrionAgent`'s own
/// `AgentSessionTests` uses to test the local (depth 1/2) path without a real MLX model load.
private struct FakeTurnGenerating: TurnGenerating {
    let response: String
    func respond(to message: String) async throws -> String { response }
}

/// End-to-end against a real analyzed fixture repo, mirroring `SemanticInvestigationRunnerTests`'
/// posture: depth 1 uses a fake local session (no MLX model, no download), depth 3 uses a
/// stand-in `claude` script (no network, no real API cost) -- `AskRunner`'s own wiring
/// (`AgentSession` construction, `AskResultSummary` mapping) is what's under test, not Phase 3's
/// already-extensively-tested internals.
final class AskRunnerTests: XCTestCase {
    private func makeAnalyzedFixtureRepo() throws -> (repoRoot: URL, outputDirectory: URL) {
        let repoRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("AskRunnerTests-\(UUID().uuidString)")
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
            .appendingPathComponent("AskRunnerTests-stub-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let scriptURL = directory.appendingPathComponent("claude")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        return scriptURL
    }

    // MARK: depth 1 -- local, budget 0, no tools, no MLX model needed for this test

    func testAskDepth1ReturnsAnUngroundedAnswerWithZeroClaims() async throws {
        let (repoRoot, outputDirectory) = try makeAnalyzedFixtureRepo()
        let session = AgentSession(
            config: AgentSessionConfig(
                repoRoot: repoRoot, outputDirectory: outputDirectory, forceDepth: 1),
            sessionFactory: { _ in FakeTurnGenerating(response: "This module defines one function.") }
        )

        let outcome = await AskRunner.ask(
            question: "What does this do?", repoRoot: repoRoot, outputDirectory: outputDirectory,
            session: session)

        guard case .answered(let summary) = outcome else {
            return XCTFail("expected .answered, got \(outcome)")
        }
        XCTAssertEqual(summary.depth, 1)
        XCTAssertEqual(summary.answerText, "This module defines one function.")
        XCTAssertEqual(summary.claimCount, 0)
        XCTAssertTrue(
            summary.isUngroundedVerified,
            "a depth-1 answer that asserted nothing must be flagged, not shown as a checked verified answer"
        )
    }

    func testAskDepth1WithForcedLowConfidenceStillProducesAnAnswer() async throws {
        // Confirms AskRunner doesn't assume any particular DepthDecision shape beyond what
        // AgentSession itself already guarantees.
        let (repoRoot, outputDirectory) = try makeAnalyzedFixtureRepo()
        let session = AgentSession(
            config: AgentSessionConfig(
                repoRoot: repoRoot, outputDirectory: outputDirectory, forceDepth: 1),
            sessionFactory: { _ in
                // >= 20 chars -- Docs/12 M5's own `minLength: 20` schema floor (found live: the
                // `claude` CLI once accepted its own literal "test" as a schema-conformant
                // answer) applies to every locally-synthesized candidate too, not just Claude's.
                FakeTurnGenerating(response: "A properly long enough answer.")
            })

        let outcome = await AskRunner.ask(
            question: "Explain foo.", repoRoot: repoRoot, outputDirectory: outputDirectory,
            session: session)

        guard case .answered(let summary) = outcome else {
            return XCTFail("expected .answered, got \(outcome)")
        }
        XCTAssertEqual(summary.routingMethod, "heuristic")  // --force-depth always reports heuristic
        XCTAssertFalse(summary.partial)
    }

    // MARK: depth 3 -- delegates to Claude, stubbed CLI

    func testAskDepth3DelegatesToClaudeAndReturnsAGroundedAnswer() async throws {
        let (repoRoot, outputDirectory) = try makeAnalyzedFixtureRepo()
        let stub = try makeStubClaude(
            """
            #!/bin/sh
            cat <<'JSON'
            {
              "structured_output": {
                "schema_version": "phase3.v1",
                "answer": "foo is defined as a no-op placeholder function in this module.",
                "claims": [{"claim_type": "INTERPRETATION", "statement": "foo does nothing.", "evidence": ["a.py::foo"], "confidence": "high"}],
                "uncertainties": []
              },
              "session_id": "sess-ask-1",
              "num_turns": 3,
              "total_cost_usd": 0.05,
              "is_error": false
            }
            JSON
            """)
        let session = AgentSession(
            config: AgentSessionConfig(
                repoRoot: repoRoot, outputDirectory: outputDirectory, forceDepth: 3,
                claudeBinary: stub.path))

        let outcome = await AskRunner.ask(
            question: "What does foo do?", repoRoot: repoRoot, outputDirectory: outputDirectory,
            session: session)

        guard case .answered(let summary) = outcome else {
            return XCTFail("expected .answered, got \(outcome)")
        }
        XCTAssertEqual(summary.depth, 3)
        XCTAssertEqual(summary.claimCount, 1)
        XCTAssertFalse(summary.isUngroundedVerified)  // depth 3, not depth 1
        // The actual point of this milestone's "reusing the same Evidence view as M5" --
        // AskRunner reads the real claim/evidence rows back, not just a count.
        let claim = try XCTUnwrap(summary.claims.first)
        XCTAssertEqual(claim.statement, "foo does nothing.")
        XCTAssertEqual(claim.claimType, "INTERPRETATION")
        XCTAssertEqual(claim.confidence, "high")
        XCTAssertEqual(claim.evidence.map(\.anchor), ["a.py::foo"])
        XCTAssertFalse(summary.partial)
    }

    func testAskDepth3SurfacesClaudeFailureAsFailedOutcome() async throws {
        let (repoRoot, outputDirectory) = try makeAnalyzedFixtureRepo()
        let stub = try makeStubClaude(
            """
            #!/bin/sh
            cat <<'JSON'
            {"is_error": true, "errors": ["Reached maximum budget ($1.00)"]}
            JSON
            """)
        let session = AgentSession(
            config: AgentSessionConfig(
                repoRoot: repoRoot, outputDirectory: outputDirectory, forceDepth: 3,
                claudeBinary: stub.path))

        let outcome = await AskRunner.ask(
            question: "What does foo do?", repoRoot: repoRoot, outputDirectory: outputDirectory,
            session: session)

        // AgentSession itself turns a failed delegation into an .answered result carrying the
        // failure as prose + partial: true (Docs/12), not an AskRunner-level `.failed` -- this
        // test documents that real behavior rather than assuming AskRunner re-interprets it.
        guard case .answered(let summary) = outcome else {
            return XCTFail("expected .answered (AgentSession's own failure-as-prose path), got \(outcome)")
        }
        XCTAssertTrue(summary.partial)
        XCTAssertTrue(summary.answerText.contains("budget"))
    }

    // MARK: no analyzed run

    func testAskOnUnanalyzedRepoFails() async throws {
        let repoRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("AskRunnerTests-unanalyzed-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: repoRoot, withIntermediateDirectories: true)
        let outputDirectory = RepositorySession.outputDirectory(forRepoRoot: repoRoot)
        try FileManager.default.createDirectory(
            at: outputDirectory, withIntermediateDirectories: true)
        // No orion.db created -- this repo was never analyzed.
        let session = AgentSession(
            config: AgentSessionConfig(repoRoot: repoRoot, outputDirectory: outputDirectory))

        let outcome = await AskRunner.ask(
            question: "Anything?", repoRoot: repoRoot, outputDirectory: outputDirectory,
            session: session)

        guard case .failed = outcome else {
            return XCTFail("expected .failed, got \(outcome)")
        }
    }
}
