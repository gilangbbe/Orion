import XCTest
import OrionCodeIntel

@testable import OrionAgent

/// `ClaudeCodeInvestigator`'s prompt/command construction (pure, no process) and its
/// wrapper-parsing (via a stand-in `claude` shell script rather than the real, paid CLI --
/// same posture as Phase 2's Python tests, which mocked `subprocess.run` rather than calling
/// the real binary). A genuinely live `claude` CLI run is a manual/optional verification step,
/// same as Phase 2's own "Manual end-to-end (not CI -- costs real API/CLI usage)".
final class ClaudeCodeInvestigatorTests: XCTestCase {

    private var keepAlive: [TempDir] = []

    /// `repoRoot` must be a real, existing directory -- `investigate()` sets it as the child
    /// process's working directory, and `Process.run()` throws a launch failure otherwise (a
    /// real bug this test file caught in itself: an earlier version pointed at a fictional
    /// `/repo` path and every `investigate()` test failed on launch, not on the assertion).
    private func makeInvestigator(
        claudeBinary: String = "claude", timeoutSeconds: Double = 900
    ) throws -> ClaudeCodeInvestigator {
        let repo = try TempDir()
        keepAlive.append(repo)
        var investigator = ClaudeCodeInvestigator(
            repoRoot: repo.url,
            exportDir: repo.url.appendingPathComponent(".orion/export"),
            claudeBinary: claudeBinary
        )
        investigator.timeoutSeconds = timeoutSeconds
        return investigator
    }

    // MARK: prompt / argument construction

    func testBuildPromptIncludesQuestionAndSchemaVersion() throws {
        let prompt = try makeInvestigator().buildPrompt(question: "What does Router.dispatch do?")
        XCTAssertTrue(prompt.contains("What does Router.dispatch do?"))
        XCTAssertTrue(prompt.contains(AgentAnswerSchema.currentVersion))
    }

    func testBuildArgumentsIsReadOnlyAndPromptIsLast() throws {
        let investigator = try makeInvestigator()
        let prompt = investigator.buildPrompt(question: "q")
        let args = try investigator.buildArguments(prompt: prompt)

        // buildArguments()[0] is the executable itself (mirrors Phase 2's build_command(),
        // whose cmd[0] is likewise self.claude_bin) -- `-p` is the first real *option*.
        XCTAssertEqual(args.first, "claude")
        XCTAssertEqual(args[1], "-p")
        XCTAssertEqual(args.last, prompt, "the prompt must be the final positional argument")
        XCTAssertTrue(args.contains("Read,Grep,Glob"))
        XCTAssertTrue(args.contains("bypassPermissions"))
        XCTAssertTrue(args.contains(investigator.exportDir.path))
        XCTAssertFalse(args.contains("Bash"), "no tool beyond Read/Grep/Glob may ever be granted")
        XCTAssertFalse(args.contains("Edit"))
        XCTAssertFalse(args.contains("Write"))
    }

    func testJSONSchemaArgumentOmitsSchemaKey() throws {
        // Docs/11 M1: the CLI's offline --json-schema validator rejects a `$schema` key
        // outright. AgentAnswerSchema.cliJSONSchema() must never include it.
        let investigator = try makeInvestigator()
        let args = try investigator.buildArguments(prompt: "p")
        guard let schemaIndex = args.firstIndex(of: "--json-schema") else {
            return XCTFail("expected a --json-schema flag")
        }
        let schemaArg = args[args.index(after: schemaIndex)]
        XCTAssertFalse(schemaArg.contains("$schema"))
        XCTAssertTrue(schemaArg.contains("phase3.v1"))
    }

    // MARK: Docs/15 §4.4 (M4) -- session continuity

    func testDefaultContinuityMatchesPrePhase5Behavior() throws {
        let investigator = try makeInvestigator()
        let args = try investigator.buildArguments(prompt: "p")
        XCTAssertTrue(args.contains("--no-session-persistence"))
        XCTAssertFalse(args.contains("--resume"))
    }

    /// Not a full-array equality check: `AgentAnswerSchema.cliJSONSchema()`'s `[String: Any]` ->
    /// `JSONSerialization` round trip has no guaranteed key order, so two separate calls can
    /// produce byte-different (but semantically identical) `--json-schema` strings even with
    /// nothing else changed -- confirmed by hitting exactly that flakiness while writing this
    /// test, not assumed. Compares the properties that actually distinguish `.none` from
    /// anything else instead.
    func testNoneContinuityIsIdenticalToDefault() throws {
        let investigator = try makeInvestigator()
        let explicit = try investigator.buildArguments(prompt: "p", continuity: .none)
        let defaulted = try investigator.buildArguments(prompt: "p")
        XCTAssertEqual(explicit.count, defaulted.count)
        XCTAssertTrue(explicit.contains("--no-session-persistence"))
        XCTAssertTrue(defaulted.contains("--no-session-persistence"))
        XCTAssertFalse(explicit.contains("--resume"))
        XCTAssertFalse(defaulted.contains("--resume"))
    }

    func testNewSessionContinuityOmitsNoSessionPersistenceAndDoesNotResume() throws {
        let investigator = try makeInvestigator()
        let args = try investigator.buildArguments(prompt: "p", continuity: .newSession)
        XCTAssertFalse(args.contains("--no-session-persistence"))
        XCTAssertFalse(args.contains("--resume"))
    }

    func testResumeContinuityAddsResumeFlagAndOmitsNoSessionPersistence() throws {
        let investigator = try makeInvestigator()
        let args = try investigator.buildArguments(prompt: "p", continuity: .resume("claude-s1"))
        XCTAssertFalse(args.contains("--no-session-persistence"))
        guard let index = args.firstIndex(of: "--resume") else {
            return XCTFail("expected a --resume flag")
        }
        XCTAssertEqual(args[args.index(after: index)], "claude-s1")
    }

    func testResumePromptOmitsTheRepositoryIntroButKeepsRulesAndQuestion() throws {
        let investigator = try makeInvestigator()
        let fresh = investigator.buildPrompt(question: "And what calls it?")
        let resumed = investigator.buildPrompt(question: "And what calls it?", continuity: .resume("claude-s1"))

        XCTAssertTrue(fresh.contains("You are investigating a Python repository"))
        XCTAssertFalse(resumed.contains("You are investigating a Python repository"))
        XCTAssertTrue(resumed.contains("follow-up question in the same Orion investigation session"))
        // Both still carry the question and the anchor/schema rules -- only the repository-
        // orientation intro is dropped, not the requirements on the answer itself.
        for prompt in [fresh, resumed] {
            XCTAssertTrue(prompt.contains("And what calls it?"))
            XCTAssertTrue(prompt.contains(AgentAnswerSchema.currentVersion))
            XCTAssertTrue(prompt.contains("Every claim's `evidence` entry"))
        }
    }

    func testMaxBudgetIsConfigurable() throws {
        var investigator = try makeInvestigator()
        investigator.maxBudgetUsd = 5.5
        let args = try investigator.buildArguments(prompt: "p")
        guard let index = args.firstIndex(of: "--max-budget-usd") else {
            return XCTFail("expected a --max-budget-usd flag")
        }
        XCTAssertEqual(args[args.index(after: index)], "5.5")
    }

    // MARK: investigate() -- wrapper parsing via a stand-in `claude` script, not the real CLI

    /// Writes an executable shell script that ignores its arguments and prints `stdout` (and
    /// optionally sleeps first, to exercise the timeout path).
    private func standIn(printing stdout: String, sleepSeconds: Int = 0) throws -> String {
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

    func testInvestigatePrefersStructuredOutputOverResultText() async throws {
        let claudePath = try standIn(
            printing: """
                {"session_id": "sess-1", "num_turns": 3, "total_cost_usd": 0.42,
                 "structured_output": {"schema_version": "phase3.v1", "answer": "structured", "claims": [], "uncertainties": []},
                 "result": "{\\"schema_version\\": \\"phase3.v1\\", \\"answer\\": \\"from result text\\", \\"claims\\": [], \\"uncertainties\\": []}"}
                """)
        let investigator = try makeInvestigator(claudeBinary: claudePath)
        let result = try await investigator.investigate(question: "q")

        XCTAssertFalse(result.timedOut)
        XCTAssertFalse(result.isError)
        XCTAssertEqual(result.sessionId, "sess-1")
        XCTAssertEqual(result.numTurns, 3)
        let findings = try JSONDecoder().decode(AgentAnswerFindings.self, from: XCTUnwrap(result.candidateData))
        XCTAssertEqual(findings.answer, "structured")
    }

    func testInvestigateFallsBackToResultTextWhenNoStructuredOutput() async throws {
        let claudePath = try standIn(
            printing: """
                {"session_id": "sess-2",
                 "result": "some preamble\\n{\\"schema_version\\": \\"phase3.v1\\", \\"answer\\": \\"from result text\\", \\"claims\\": [], \\"uncertainties\\": []}\\ntrailing"}
                """)
        let investigator = try makeInvestigator(claudeBinary: claudePath)
        let result = try await investigator.investigate(question: "q")

        let findings = try JSONDecoder().decode(AgentAnswerFindings.self, from: XCTUnwrap(result.candidateData))
        XCTAssertEqual(findings.answer, "from result text")
    }

    func testInvestigateReportsIsError() async throws {
        let claudePath = try standIn(printing: #"{"is_error": true, "result": "something went wrong"}"#)
        let investigator = try makeInvestigator(claudeBinary: claudePath)
        let result = try await investigator.investigate(question: "q")
        XCTAssertTrue(result.isError)
    }

    /// Real failure mode found live (M5): a run that hits `--max-budget-usd` before producing a
    /// final answer sets `is_error: true` with no `result`/`structured_output` at all, but does
    /// name the reason in `errors`/`subtype` -- worth surfacing instead of a generic "no output."
    func testInvestigateSurfacesBudgetExhaustedErrorMessage() async throws {
        let claudePath = try standIn(
            printing: """
                {"is_error": true, "subtype": "error_max_budget_usd",
                 "errors": ["Reached maximum budget ($0.5)"]}
                """)
        let investigator = try makeInvestigator(claudeBinary: claudePath)
        let result = try await investigator.investigate(question: "q")
        XCTAssertTrue(result.isError)
        XCTAssertEqual(result.errorMessage, "Reached maximum budget ($0.5)")
    }

    func testInvestigateHandlesNoStdoutAtAll() async throws {
        let claudePath = try standIn(printing: "")
        let investigator = try makeInvestigator(claudeBinary: claudePath)
        let result = try await investigator.investigate(question: "q")
        XCTAssertTrue(result.isError)
        XCTAssertNil(result.candidateData)
    }

    func testInvestigatePicksDominantModelByCost() async throws {
        let claudePath = try standIn(
            printing: """
                {"modelUsage": {"claude-haiku-4-5": {"costUSD": 0.01}, "claude-sonnet-5": {"costUSD": 1.2}},
                 "result": "{\\"schema_version\\": \\"phase3.v1\\", \\"answer\\": \\"x\\", \\"claims\\": [], \\"uncertainties\\": []}"}
                """)
        let investigator = try makeInvestigator(claudeBinary: claudePath)
        let result = try await investigator.investigate(question: "q")
        XCTAssertEqual(result.modelUsed, "claude-sonnet-5")
    }

    func testInvestigateTimesOutOnASlowStandIn() async throws {
        let claudePath = try standIn(printing: #"{"answer": "too slow"}"#, sleepSeconds: 10)
        var investigator = try makeInvestigator(claudeBinary: claudePath)
        investigator.timeoutSeconds = 1

        let start = ContinuousClock.now
        let result = try await investigator.investigate(question: "q")
        let elapsed = start.duration(to: .now)

        XCTAssertTrue(result.timedOut)
        XCTAssertNil(result.candidateData)
        XCTAssertLessThan(elapsed, .seconds(5))
    }

    func testInvestigationMetaMapsFieldsCorrectly() {
        let result = ClaudeCodeInvestigationResult(
            rawWrapper: Data(), candidateData: nil, sessionId: "s1", modelUsed: "claude-sonnet-5",
            numTurns: 7, totalCostUsd: 1.23, durationMs: 4500, timedOut: false, isError: false,
            stderrTail: ""
        )
        let meta = result.investigationMeta
        XCTAssertEqual(meta.modelUsed, "claude-sonnet-5")
        XCTAssertEqual(meta.sessionId, "s1")
        XCTAssertEqual(meta.numTurns, 7)
        XCTAssertEqual(meta.totalCostUsd, 1.23)
        XCTAssertEqual(meta.toolsUsed, ["Read", "Grep", "Glob"])
    }
}
