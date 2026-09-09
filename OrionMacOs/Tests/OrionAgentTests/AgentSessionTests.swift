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

    /// Docs/15_phase5_adaptive_exploration.md §11 M8, Risk #7: the real 55-question benchmark
    /// hit the exact `--max-budget-usd` ceiling a second time (`XF-01`, at the very default this
    /// test configures) -- the fix is a more actionable failure message, not a new default.
    /// Reproduces the wrapper shape Docs/12 M5 found live for a budget-exhausted run
    /// (`is_error: true`, `errors: [...]`, `subtype: "error_max_budget_usd"`).
    func testBudgetExhaustedFailureSurfacesTheConfiguredCeilingAndTheFlagToRaiseIt() async throws {
        let (repoRoot, outDir) = try analyzed()
        let claudePath = try standInClaude(
            printing: """
                {"is_error": true, "subtype": "error_max_budget_usd",
                 "errors": ["Reached maximum budget ($1)"]}
                """)
        let config = AgentSessionConfig(
            repoRoot: repoRoot, outputDirectory: outDir, forceDepth: 3, maxBudgetUsd: 1.00,
            claudeBinary: claudePath
        )
        let result = try await AgentSession(config: config, sessionFactory: { _ in ScriptedSession([]) })
            .ask("What does the Router class do?")

        XCTAssertTrue(result.answerText.contains("Reached maximum budget"))
        XCTAssertTrue(
            result.answerText.contains("--max-budget-usd"),
            "must name the actual flag to raise, not just repeat the CLI's own error: \(result.answerText)")
        XCTAssertTrue(result.answerText.contains("$1.0"), "must name the real configured ceiling, not a generic message")
    }

    // MARK: guardrail (Docs/15 §3) -- exercised through the real (non-forced) routing path,
    // using an injected stub `DepthFallbackClassifying` rather than `--force-depth`, since a
    // forced depth always stays in scope by design and so can never reach `declineOutOfScope`.

    private struct StubDepthFallback: DepthFallbackClassifying {
        let result: DepthDecision
        func classify(_ question: String) async throws -> DepthDecision { result }
    }

    func testOutOfScopeQuestionIsDeclinedWithoutLoadingAnyModel() async throws {
        let (repoRoot, outDir) = try analyzed()
        let config = AgentSessionConfig(repoRoot: repoRoot, outputDirectory: outDir)
        let fallback = StubDepthFallback(
            result: DepthDecision(
                depth: 3, intent: "unclassified", confidence: .low,
                rationale: "This looks like a general knowledge question, not one about the"
                    + " analyzed repository.",
                method: .model, isInScope: false))
        // No `sessionFactory` script is ever consumed -- an empty script plus `ScriptedSession`'s
        // own `XCTFail` on an unexpected call is what actually proves the local model was never
        // touched; `ClaudeCodeInvestigator` is never even constructed on this path (no
        // `claudeBinary` stand-in needed at all, unlike every depth-3 test above).
        let result = try await AgentSession(
            config: config, sessionFactory: { _ in ScriptedSession([]) }, depthFallback: fallback
        ).ask("What's a good recipe for pasta?")

        XCTAssertFalse(result.depthDecision.isInScope)
        XCTAssertEqual(result.investigation.outcome, InvestigationOutcome.declined.rawValue)
        XCTAssertEqual(result.investigation.complexity, "none")
        XCTAssertNil(result.investigation.modelUsed)
        XCTAssertEqual(result.claimCount, 0)
        XCTAssertFalse(result.partial, "a decline is a correct, complete result, not a failure")
        XCTAssertTrue(result.answerText.contains("analyzed repository"))
        XCTAssertTrue(result.toolCalls.isEmpty)

        let store = Store(try OrionDatabase(path: outDir.appendingPathComponent("orion.db").path))
        let routing = try store.routingDecisions(investigationId: result.investigation.id)
        XCTAssertEqual(routing.count, 1, "the decline is still a persisted, --explain-visible routing decision")
        XCTAssertEqual(routing.first?.confidence, "low")
        XCTAssertTrue(try store.agentToolCalls(investigationId: result.investigation.id).isEmpty)
    }

    func testInScopeQuestionThroughTheRealRoutingPathIsNotDeclined() async throws {
        let (repoRoot, outDir) = try analyzed()
        let config = AgentSessionConfig(repoRoot: repoRoot, outputDirectory: outDir)
        let fallback = StubDepthFallback(
            result: DepthDecision(
                depth: 1, intent: "component_purpose", confidence: .high,
                rationale: "Simple enough for local knowledge.", method: .model, isInScope: true))
        let result = try await AgentSession(
            config: config,
            sessionFactory: { _ in ScriptedSession(["Router dispatches requests to handlers."]) },
            depthFallback: fallback
        ).ask("What does the Router do?")

        XCTAssertTrue(result.depthDecision.isInScope)
        XCTAssertNotEqual(result.investigation.outcome, InvestigationOutcome.declined.rawValue)
        XCTAssertEqual(result.answerText, "Router dispatches requests to handlers.")
    }

    /// `--force-depth` always stays in scope, even paired with a fallback that would decline --
    /// Docs/15 §3.2: a deliberate developer override must never be silently declined.
    func testForceDepthBypassesTheGuardrailEntirely() async throws {
        let (repoRoot, outDir) = try analyzed()
        let fallback = StubDepthFallback(
            result: DepthDecision(
                depth: 3, intent: "unclassified", confidence: .low, rationale: "would decline",
                method: .model, isInScope: false))
        let config = AgentSessionConfig(repoRoot: repoRoot, outputDirectory: outDir, forceDepth: 1)
        let result = try await AgentSession(
            config: config, sessionFactory: { _ in ScriptedSession(["Starlette is a framework."]) },
            depthFallback: fallback
        ).ask("What's a good recipe for pasta?")

        XCTAssertTrue(result.depthDecision.isInScope)
        XCTAssertEqual(result.depthDecision.depth, 1)
        XCTAssertNotEqual(result.investigation.outcome, InvestigationOutcome.declined.rawValue)
    }

    // MARK: sessions (Docs/15 §4, M3)

    /// Captures the `instructions` string `sessionFactory` was actually called with -- the only
    /// way to observe whether `ContextBuilder`'s `priorTurns`/`componentContext` really reached
    /// the model-facing prompt, since `ScriptedSession` itself discards it.
    private final class InstructionsCapture: @unchecked Sendable {
        var value: String?
    }

    private func sessionWithCapture(
        repoRoot: URL, outDir: URL, forceDepth: Int, script: [String], capture: InstructionsCapture
    ) -> AgentSession {
        let config = AgentSessionConfig(
            repoRoot: repoRoot, outputDirectory: outDir, forceDepth: forceDepth,
            maxBudgetUsd: 1.00, timeoutSeconds: 5)
        return AgentSession(
            config: config,
            sessionFactory: { instructions in
                capture.value = instructions
                return ScriptedSession(script)
            })
    }

    func testAskWithUnknownSessionIdThrows() async throws {
        let (repoRoot, outDir) = try analyzed()
        await XCTAssertThrowsErrorAsync(
            try await session(repoRoot: repoRoot, outDir: outDir, forceDepth: 1, script: ["x"])
                .ask("What does Router do?", sessionId: "no-such-session")
        )
    }

    func testSessionTurnIsRecordedAfterASuccessfulAnswer() async throws {
        let (repoRoot, outDir) = try analyzed()
        let store = Store(try OrionDatabase(path: outDir.appendingPathComponent("orion.db").path))
        guard let run = try store.latestRun(commitHash: nil) else { return XCTFail("expected an analyzed run") }
        let askSession = try store.createAskSession(
            repositoryId: run.repositoryId, commitHash: run.commitHash, scopeType: .repository,
            title: "General", now: "t0")

        let result = try await session(
            repoRoot: repoRoot, outDir: outDir, forceDepth: 1,
            script: ["Starlette is a lightweight ASGI framework."]
        ).ask("What does Starlette do?", sessionId: askSession.id)

        let turns = try store.askSessionTurns(sessionId: askSession.id)
        XCTAssertEqual(turns.count, 1)
        XCTAssertEqual(turns.first?.investigationId, result.investigation.id)
        XCTAssertEqual(try store.askSession(id: askSession.id)?.turnCount, 1)
    }

    /// Docs/15 §4.5 step 3: a decline never advances the session it happened in.
    func testDeclinedQuestionInASessionDoesNotAdvanceTurnCount() async throws {
        let (repoRoot, outDir) = try analyzed()
        let store = Store(try OrionDatabase(path: outDir.appendingPathComponent("orion.db").path))
        guard let run = try store.latestRun(commitHash: nil) else { return XCTFail("expected an analyzed run") }
        let askSession = try store.createAskSession(
            repositoryId: run.repositoryId, commitHash: run.commitHash, scopeType: .repository,
            title: "General", now: "t0")
        let fallback = StubDepthFallback(
            result: DepthDecision(
                depth: 3, intent: "unclassified", confidence: .low, rationale: "off topic",
                method: .model, isInScope: false))
        let config = AgentSessionConfig(repoRoot: repoRoot, outputDirectory: outDir)

        let result = try await AgentSession(
            config: config, sessionFactory: { _ in ScriptedSession([]) }, depthFallback: fallback
        ).ask("What's a good recipe for pasta?", sessionId: askSession.id)

        XCTAssertEqual(result.investigation.outcome, InvestigationOutcome.declined.rawValue)
        XCTAssertEqual(try store.askSession(id: askSession.id)?.turnCount, 0)
        XCTAssertTrue(try store.askSessionTurns(sessionId: askSession.id).isEmpty)
    }

    func testSecondTurnIsPrimedWithTheFirstTurnsQuestionAndAnswer() async throws {
        let (repoRoot, outDir) = try analyzed()
        let store = Store(try OrionDatabase(path: outDir.appendingPathComponent("orion.db").path))
        guard let run = try store.latestRun(commitHash: nil) else { return XCTFail("expected an analyzed run") }
        let askSession = try store.createAskSession(
            repositoryId: run.repositoryId, commitHash: run.commitHash, scopeType: .repository,
            title: "General", now: "t0")

        _ = try await session(
            repoRoot: repoRoot, outDir: outDir, forceDepth: 1,
            script: ["Router dispatches requests to handlers."]
        ).ask("What does the Router do?", sessionId: askSession.id)

        let capture = InstructionsCapture()
        _ = try await sessionWithCapture(
            repoRoot: repoRoot, outDir: outDir, forceDepth: 1,
            script: ["It calls handlers.handle."], capture: capture
        ).ask("And what does it call?", sessionId: askSession.id)

        let instructions = try XCTUnwrap(capture.value)
        XCTAssertTrue(instructions.contains("Conversation so far"))
        XCTAssertTrue(instructions.contains("What does the Router do?"))
        XCTAssertTrue(instructions.contains("Router dispatches requests to handlers."))
    }

    func testFirstTurnInASessionCarriesNoPriorTurnsSection() async throws {
        let (repoRoot, outDir) = try analyzed()
        let store = Store(try OrionDatabase(path: outDir.appendingPathComponent("orion.db").path))
        guard let run = try store.latestRun(commitHash: nil) else { return XCTFail("expected an analyzed run") }
        let askSession = try store.createAskSession(
            repositoryId: run.repositoryId, commitHash: run.commitHash, scopeType: .repository,
            title: "General", now: "t0")

        let capture = InstructionsCapture()
        _ = try await sessionWithCapture(
            repoRoot: repoRoot, outDir: outDir, forceDepth: 1,
            script: ["Starlette is a framework."], capture: capture
        ).ask("What does Starlette do?", sessionId: askSession.id)

        XCTAssertFalse(try XCTUnwrap(capture.value).contains("Conversation so far"))
    }

    func testComponentScopedSessionPrimesComponentContext() async throws {
        let (repoRoot, outDir) = try analyzed()
        let store = Store(try OrionDatabase(path: outDir.appendingPathComponent("orion.db").path))
        guard let run = try store.latestRun(commitHash: nil) else { return XCTFail("expected an analyzed run") }
        // A minimal, real semantic investigation so a real `components` row exists to scope a
        // session to -- `SemanticImporter.ingest` directly, no `claude` stub needed (this test
        // only cares what `AgentSession` does with an already-persisted component).
        let candidate = """
            {"schema_version": "phase2.v1",
             "components": [{"name": "Routing", "description": "Routes requests.",
               "architectural_role": "core", "members": ["pkg/router.py::Router"]}],
             "component_relationships": [], "claims": [], "uncertainties": []}
            """
        let candidateFile = outDir.appendingPathComponent("candidate.json")
        try candidate.write(to: candidateFile, atomically: true, encoding: .utf8)
        let ingestOutcome = try SemanticImporter(store: store).ingest(
            candidateURL: candidateFile, metaURL: nil, run: run, now: "t0")
        let componentId = try XCTUnwrap(store.components(investigationId: ingestOutcome.investigation.id).first?.id)

        let askSession = try store.createAskSession(
            repositoryId: run.repositoryId, commitHash: run.commitHash, scopeType: .component,
            componentId: componentId, title: "About Routing", now: "t0")

        let capture = InstructionsCapture()
        _ = try await sessionWithCapture(
            repoRoot: repoRoot, outDir: outDir, forceDepth: 1,
            script: ["Routing dispatches to handlers."], capture: capture
        ).ask("Tell me more.", sessionId: askSession.id)

        let instructions = try XCTUnwrap(capture.value)
        XCTAssertTrue(instructions.contains("focused on one specific component"))
        XCTAssertTrue(instructions.contains("Component: Routing"))
        XCTAssertTrue(instructions.contains("pkg/router.py::Router"))
    }

    func testDepth3TurnInASessionCapturesClaudeSessionIdForFutureResume() async throws {
        let (repoRoot, outDir) = try analyzed()
        let store = Store(try OrionDatabase(path: outDir.appendingPathComponent("orion.db").path))
        guard let run = try store.latestRun(commitHash: nil) else { return XCTFail("expected an analyzed run") }
        let askSession = try store.createAskSession(
            repositoryId: run.repositoryId, commitHash: run.commitHash, scopeType: .repository,
            title: "General", now: "t0")
        let claudePath = try standInClaude(
            printing: """
                {"session_id": "claude-s1", "num_turns": 4, "total_cost_usd": 0.30,
                 "result": "{\\"schema_version\\": \\"phase3.v1\\", \\"answer\\": \\"Router dispatches via handlers.\\", \\"claims\\": [], \\"uncertainties\\": []}"}
                """)

        _ = try await session(
            repoRoot: repoRoot, outDir: outDir, forceDepth: 3, claudeBinary: claudePath
        ).ask("What does the Router class do?", sessionId: askSession.id)

        XCTAssertEqual(try store.askSession(id: askSession.id)?.claudeSessionId, "claude-s1")
    }

    /// Docs/15 §4.4 (M4), end to end through `AgentSession`: a session-less depth-3 call still
    /// gets `--no-session-persistence` -- confirms the M4 change to `runDelegated` didn't touch
    /// the one path that must stay byte-for-byte the pre-Phase-5 behavior.
    func testSessionLessDepth3CallStillPassesNoSessionPersistence() async throws {
        let (repoRoot, outDir) = try analyzed()
        let argsFile = outDir.appendingPathComponent("claude-args.txt").path
        let claudePath = try standInClaudeCapturingArgs(
            printing: #"{"answer": "irrelevant for this test"}"#, argsFile: argsFile)

        _ = try await session(
            repoRoot: repoRoot, outDir: outDir, forceDepth: 3, claudeBinary: claudePath
        ).ask("What does the Router class do?")

        let capturedArgs = try String(contentsOfFile: argsFile, encoding: .utf8)
        XCTAssertTrue(capturedArgs.contains("--no-session-persistence"))
        XCTAssertFalse(capturedArgs.contains("--resume"))
    }

    /// A session's *first* depth-3 turn: no `claudeSessionId` to resume yet, but the CLI must be
    /// told to persist this one for a possible later resume.
    func testFirstDepth3TurnInASessionOmitsNoSessionPersistence() async throws {
        let (repoRoot, outDir) = try analyzed()
        let store = Store(try OrionDatabase(path: outDir.appendingPathComponent("orion.db").path))
        guard let run = try store.latestRun(commitHash: nil) else { return XCTFail("expected an analyzed run") }
        let askSession = try store.createAskSession(
            repositoryId: run.repositoryId, commitHash: run.commitHash, scopeType: .repository,
            title: "General", now: "t0")
        let argsFile = outDir.appendingPathComponent("claude-args.txt").path
        let claudePath = try standInClaudeCapturingArgs(
            printing: #"{"session_id": "claude-s1", "answer": "irrelevant for this test"}"#,
            argsFile: argsFile)

        _ = try await session(
            repoRoot: repoRoot, outDir: outDir, forceDepth: 3, claudeBinary: claudePath
        ).ask("What does the Router class do?", sessionId: askSession.id)

        let capturedArgs = try String(contentsOfFile: argsFile, encoding: .utf8)
        XCTAssertFalse(capturedArgs.contains("--no-session-persistence"))
        XCTAssertFalse(capturedArgs.contains("--resume"))
    }

    /// The actual point of M4: a session's *second* depth-3 turn resumes the first's real Claude
    /// session id, end to end through `AgentSession` -- not just unit-tested at
    /// `ClaudeCodeInvestigator`'s own level.
    func testSecondDepth3TurnInASessionResumesTheFirstsClaudeSession() async throws {
        let (repoRoot, outDir) = try analyzed()
        let store = Store(try OrionDatabase(path: outDir.appendingPathComponent("orion.db").path))
        guard let run = try store.latestRun(commitHash: nil) else { return XCTFail("expected an analyzed run") }
        let askSession = try store.createAskSession(
            repositoryId: run.repositoryId, commitHash: run.commitHash, scopeType: .repository,
            title: "General", now: "t0")
        let firstClaudePath = try standInClaude(
            printing: """
                {"session_id": "claude-s1",
                 "result": "{\\"schema_version\\": \\"phase3.v1\\", \\"answer\\": \\"Router dispatches via handlers.\\", \\"claims\\": [], \\"uncertainties\\": []}"}
                """)
        _ = try await session(
            repoRoot: repoRoot, outDir: outDir, forceDepth: 3, claudeBinary: firstClaudePath
        ).ask("What does the Router class do?", sessionId: askSession.id)
        XCTAssertEqual(try store.askSession(id: askSession.id)?.claudeSessionId, "claude-s1")

        let argsFile = outDir.appendingPathComponent("claude-args-2.txt").path
        let secondClaudePath = try standInClaudeCapturingArgs(
            printing: """
                {"session_id": "claude-s1",
                 "result": "{\\"schema_version\\": \\"phase3.v1\\", \\"answer\\": \\"It calls handlers.handle.\\", \\"claims\\": [], \\"uncertainties\\": []}"}
                """, argsFile: argsFile)
        _ = try await session(
            repoRoot: repoRoot, outDir: outDir, forceDepth: 3, claudeBinary: secondClaudePath
        ).ask("And what does it call?", sessionId: askSession.id)

        let capturedArgs = try String(contentsOfFile: argsFile, encoding: .utf8)
        XCTAssertFalse(capturedArgs.contains("--no-session-persistence"))
        XCTAssertTrue(capturedArgs.contains("--resume"))
        XCTAssertTrue(capturedArgs.contains("claude-s1"))
        // The resumed turn's prompt must not re-state the full repository-orientation intro.
        XCTAssertFalse(capturedArgs.contains("You are investigating a Python repository"))
        XCTAssertTrue(capturedArgs.contains("And what does it call?"))
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
