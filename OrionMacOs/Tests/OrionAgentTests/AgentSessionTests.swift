import XCTest
import OrionCodeIntel

@testable import OrionAgent

/// Docs/12_phase3_mlx_agent.md M4 ("State management + CLI"): `AgentSession` wires
/// `DepthModel` -> local `ActionLoop` (depth 1/2) or `ClaudeCodeInvestigator` (depth 3) ->
/// `SemanticImporter` -> `routing_decisions`/`agent_tool_calls` persistence. No live model, no
/// network: depth 1/2 use an injected scripted `TurnGenerating` stub (the same seam
/// `ActionLoopTests` uses for `ActionLoop` itself), depth 3 uses a stand-in `claude` shell
/// script (the same approach `ClaudeCodeInvestigatorTests` uses).
final class AgentSessionTests: XCTestCase {

    private var keepAlive: [TempDir] = []

    /// Replays a fixed script of responses, one per call to `respond(to:)`.
    private final class ScriptedSession: TurnGenerating {
        private var script: [String]
        init(_ script: [String]) { self.script = script }
        func respond(to message: String) async throws -> String {
            guard !script.isEmpty else {
                XCTFail("ScriptedSession ran out of scripted responses")
                return "{}"
            }
            return script.removeFirst()
        }
    }

    /// `pkg/router.py` imports `pkg/handlers.py` and defines `Router` -- a real, findable
    /// symbol `lookup_symbol` can resolve, and a real import edge `resolve: false` still
    /// produces (tree-sitter/AST level, no scip needed) -- same shape `ActionLoopLiveTests`
    /// and `AgentAnswerImporterTests` already use.
    private func analyzed() throws -> (repoRoot: URL, outDir: URL) {
        let repo = try TempDir()
        keepAlive.append(repo)
        let git = GitRunner(repoPath: repo.url)
        _ = try git.run(["init", "--quiet", "-b", "main"])
        _ = try git.run(["config", "user.email", "t@e.com"])
        _ = try git.run(["config", "user.name", "T"])
        try repo.write("pkg/__init__.py", "")
        try repo.write(
            "pkg/router.py",
            "from pkg import handlers\n\nclass Router:\n    def dispatch(self, path):\n        return handlers.handle(path)\n"
        )
        try repo.write("pkg/handlers.py", "def handle(path):\n    return path\n")
        _ = try git.run(["add", "."])
        _ = try git.run(["commit", "--quiet", "-m", "init"])

        let out = try TempDir()
        keepAlive.append(out)
        let db = try OrionDatabase(path: out.path("orion.db"))
        _ = try AnalysisPipeline(database: db).run(
            AnalysisInput(repoPath: repo.url, outputDirectory: out.url, resolve: false, export: false)
        )
        return (repo.url, out.url)
    }

    private func session(
        repoRoot: URL, outDir: URL, forceDepth: Int, script: [String] = [],
        claudeBinary: String = "claude"
    ) -> AgentSession {
        let config = AgentSessionConfig(
            repoRoot: repoRoot, outputDirectory: outDir, forceDepth: forceDepth,
            maxBudgetUsd: 1.00, timeoutSeconds: 5, claudeBinary: claudeBinary
        )
        return AgentSession(config: config, sessionFactory: { _ in ScriptedSession(script) })
    }

    // MARK: depth 1 -- local, no tools

    func testForceDepth1RunsLocalWithNoTools() async throws {
        let (repoRoot, outDir) = try analyzed()
        let result = try await session(
            repoRoot: repoRoot, outDir: outDir, forceDepth: 1,
            script: ["Starlette is a lightweight ASGI framework."]
        ).ask("What does Starlette do?")

        XCTAssertEqual(result.depthDecision.depth, 1)
        XCTAssertEqual(result.answerText, "Starlette is a lightweight ASGI framework.")
        XCTAssertTrue(result.toolCalls.isEmpty)
        XCTAssertEqual(result.investigation.complexity, "low")
        // No evidence anchors were ever offered -- classifyAnswerOutcome treats a pure-prose
        // answer as verified: nothing was asserted, so nothing failed to substantiate.
        XCTAssertEqual(result.investigation.outcome, InvestigationOutcome.verified.rawValue)
        XCTAssertEqual(result.claimCount, 0)

        let store = Store(try OrionDatabase(path: outDir.appendingPathComponent("orion.db").path))
        let routing = try store.routingDecisions(investigationId: result.investigation.id)
        XCTAssertEqual(routing.count, 1)
        XCTAssertEqual(routing.first?.depthLevel, 1)
        XCTAssertEqual(routing.first?.method, "heuristic")
        XCTAssertTrue(try store.agentToolCalls(investigationId: result.investigation.id).isEmpty)
    }

    // MARK: depth 2 -- local + tools

    func testForceDepth2RunsToolLoopAndPersistsTrace() async throws {
        let (repoRoot, outDir) = try analyzed()
        let result = try await session(
            repoRoot: repoRoot, outDir: outDir, forceDepth: 2,
            script: [
                #"{"action": "call_tool", "tool": "lookup_symbol", "arguments": {"query": "Router"}}"#,
                #"{"action": "answer", "text": "Router dispatches requests to handlers."}"#,
            ]
        ).ask("What does the Router class do?")

        XCTAssertEqual(result.depthDecision.depth, 2)
        XCTAssertEqual(result.answerText, "Router dispatches requests to handlers.")
        XCTAssertEqual(result.toolCalls.count, 1)
        XCTAssertEqual(result.investigation.complexity, "medium")

        let store = Store(try OrionDatabase(path: outDir.appendingPathComponent("orion.db").path))
        let calls = try store.agentToolCalls(investigationId: result.investigation.id)
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.toolName, "lookup_symbol")

        // The tool actually found `pkg/router.py::Router` -- EvidenceAnchors should have pulled
        // that anchor out of the tool's own result text, and it should resolve for real.
        XCTAssertEqual(result.claimCount, 1)
        XCTAssertEqual(result.droppedClaimCount, 0)
    }

    func testForceDepth2WithNoGroundedEvidenceIsUnverified() async throws {
        let (repoRoot, outDir) = try analyzed()
        let result = try await session(
            repoRoot: repoRoot, outDir: outDir, forceDepth: 2,
            script: [
                #"{"action": "call_tool", "tool": "lookup_symbol", "arguments": {"query": "NoSuchThing"}}"#,
                #"{"action": "answer", "text": "I could not find anything relevant."}"#,
            ]
        ).ask("What does NoSuchThing do?")

        // A tool call was made, but nothing anchor-shaped came back to ground a claim in --
        // submitting one anyway (rather than none) makes the failure to ground visible instead
        // of indistinguishable from a plain, nothing-asserted depth-1 answer.
        XCTAssertEqual(result.claimCount, 0)
        XCTAssertEqual(result.investigation.outcome, InvestigationOutcome.unverified.rawValue)
    }

    // MARK: depth 3 -- delegate to Claude Code (stand-in script, no real CLI/network)

    private func standInClaude(printing stdout: String, sleepSeconds: Int = 0) throws -> String {
        let dir = try TempDir()
        keepAlive.append(dir)
        let scriptPath = dir.path("claude")
        let script = """
            #!/bin/sh
            \(sleepSeconds > 0 ? "sleep \(sleepSeconds)" : "")
            cat <<'EOF'
            \(stdout)
            EOF
            """
        try script.write(toFile: scriptPath, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptPath)
        return scriptPath
    }

    /// Like `standInClaude`, but also dumps its own received arguments to `argsFile` before
    /// printing -- lets a test confirm `AgentSessionConfig.maxBudgetUsd`/`timeoutSeconds`
    /// actually reach the real subprocess invocation end to end, not just that
    /// `ClaudeCodeInvestigator` builds the right arguments in isolation
    /// (`ClaudeCodeInvestigatorTests` already covers that).
    private func standInClaudeCapturingArgs(printing stdout: String, argsFile: String) throws -> String {
        let dir = try TempDir()
        keepAlive.append(dir)
        let scriptPath = dir.path("claude")
        let script = """
            #!/bin/sh
            printf '%s\\n' "$@" > "\(argsFile)"
            cat <<'EOF'
            \(stdout)
            EOF
            """
        try script.write(toFile: scriptPath, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptPath)
        return scriptPath
    }

    /// Docs/12_phase3_mlx_agent.md M6: `--max-budget-usd`/`--timeout` enforcement for L3,
    /// verified end to end through `AgentSession`, not just at `ClaudeCodeInvestigator`'s own
    /// unit level. Confirms `AgentSessionConfig.maxBudgetUsd` really reaches the real
    /// subprocess's argv, exactly as configured -- not just that the right *value* is stored
    /// somewhere along the way.
    func testForceDepth3PropagatesConfiguredMaxBudgetToTheRealSubprocess() async throws {
        let (repoRoot, outDir) = try analyzed()
        let argsFile = outDir.appendingPathComponent("claude-args.txt").path
        let claudePath = try standInClaudeCapturingArgs(
            printing: #"{"answer": "irrelevant for this test"}"#, argsFile: argsFile)
        let config = AgentSessionConfig(
            repoRoot: repoRoot, outputDirectory: outDir, forceDepth: 3, maxBudgetUsd: 0.42,
            timeoutSeconds: 30, claudeBinary: claudePath
        )
        _ = try await AgentSession(config: config, sessionFactory: { _ in ScriptedSession([]) })
            .ask("What does the Router class do?")

        let capturedArgs = try String(contentsOfFile: argsFile, encoding: .utf8)
        XCTAssertTrue(capturedArgs.contains("--max-budget-usd"))
        XCTAssertTrue(capturedArgs.contains("0.42"), "the configured budget, not some default, must reach argv")
    }

    /// The watchdog side of the same enforcement: a real subprocess that ignores its work and
    /// just sleeps past `timeoutSeconds` must actually be killed, end to end through
    /// `AgentSession` -- `ProcessRunnerTests`/`ClaudeCodeInvestigatorTests` already cover the
    /// mechanism in isolation; this confirms the *configured* value governs a real `AgentSession`
    /// run and the process doesn't outlive it.
    func testForceDepth3TimeoutEnforcedEndToEndWithinConfiguredBound() async throws {
        let (repoRoot, outDir) = try analyzed()
        let claudePath = try standInClaude(printing: #"{"answer": "too slow"}"#, sleepSeconds: 30)
        let config = AgentSessionConfig(
            repoRoot: repoRoot, outputDirectory: outDir, forceDepth: 3, maxBudgetUsd: 1.00,
            timeoutSeconds: 2, claudeBinary: claudePath
        )

        let start = ContinuousClock.now
        let result = try await AgentSession(config: config, sessionFactory: { _ in ScriptedSession([]) })
            .ask("What does the Router class do?")
        let elapsed = start.duration(to: .now)

        XCTAssertLessThan(elapsed, .seconds(10), "must be killed near the 2s bound, not wait out the 30s sleep")
        XCTAssertEqual(result.investigation.outcome, InvestigationOutcome.incomplete.rawValue)
    }

    func testForceDepth3IngestsAValidClaudeAnswer() async throws {
        let (repoRoot, outDir) = try analyzed()
        let claudePath = try standInClaude(
            printing: """
                {"session_id": "s1", "num_turns": 4, "total_cost_usd": 0.30,
                 "result": "{\\"schema_version\\": \\"phase3.v1\\", \\"answer\\": \\"Router dispatches via handlers.\\", \\"claims\\": [{\\"claim_type\\": \\"INTERPRETATION\\", \\"statement\\": \\"Router dispatches via handlers.\\", \\"evidence\\": [\\"pkg/router.py::Router\\"], \\"confidence\\": \\"high\\"}], \\"uncertainties\\": []}"}
                """)
        let result = try await session(
            repoRoot: repoRoot, outDir: outDir, forceDepth: 3, claudeBinary: claudePath
        ).ask("What does the Router class do?")

        XCTAssertEqual(result.depthDecision.depth, 3)
        XCTAssertEqual(result.answerText, "Router dispatches via handlers.")
        XCTAssertEqual(result.investigation.complexity, "high")
        XCTAssertEqual(result.claimCount, 1)
        XCTAssertFalse(result.partial)

        let store = Store(try OrionDatabase(path: outDir.appendingPathComponent("orion.db").path))
        let routing = try store.routingDecisions(investigationId: result.investigation.id)
        XCTAssertEqual(routing.first?.depthLevel, 3)
        // L3's tool calls are Claude's own internal Read/Grep/Glob usage, not something this
        // process observes turn-by-turn -- agent_tool_calls stays empty for depth 3 by design.
        XCTAssertTrue(try store.agentToolCalls(investigationId: result.investigation.id).isEmpty)
    }

    func testForceDepth3TimeoutIsPersistedAsIncompleteNotThrown() async throws {
        let (repoRoot, outDir) = try analyzed()
        let claudePath = try standInClaude(printing: #"{"answer": "too slow"}"#, sleepSeconds: 10)
        let config = AgentSessionConfig(
            repoRoot: repoRoot, outputDirectory: outDir, forceDepth: 3, maxBudgetUsd: 1.00,
            timeoutSeconds: 1, claudeBinary: claudePath
        )
        let result = try await AgentSession(config: config, sessionFactory: { _ in ScriptedSession([]) })
            .ask("What does the Router class do?")

        XCTAssertEqual(result.investigation.outcome, InvestigationOutcome.incomplete.rawValue)
        XCTAssertTrue(result.partial)
        XCTAssertTrue(result.answerText.lowercased().contains("timed out"))
    }

    // MARK: no analyzed run

    func testAskWithoutAnAnalyzedRunThrows() async throws {
        let repo = try TempDir()
        keepAlive.append(repo)
        let out = try TempDir()
        keepAlive.append(out)
        let config = AgentSessionConfig(repoRoot: repo.url, outputDirectory: out.url, forceDepth: 1)

        await XCTAssertThrowsErrorAsync(
            try await AgentSession(config: config, sessionFactory: { _ in ScriptedSession(["x"]) })
                .ask("anything")
        )
    }
}
