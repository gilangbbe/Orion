import XCTest
import OrionCodeIntel

@testable import OrionAgent

/// The M2 end-to-end check: `ActionLoop` driving real `Qwen3-8B-4bit` against real
/// `QueryEngine`-backed tools over a small analyzed repo -- not the toy canned-string tool the
/// Risk #3 experiments used. Requires `ORION_AGENT_LIVE_MODEL_TEST=1`, not run in CI. Run via
/// `xcodebuild build-for-testing` + `xcrun xctest -XCTest <bundle> <path>` (confirmed to
/// inherit the invoking shell's environment, unlike `xcodebuild test`) -- see
/// `Qwen3NonThinkingToolCallingLiveTests`'s doc comment for the exact commands. **Confirmed
/// live**: 11.8s for a full multi-turn investigation (real tool calls, grounded final answer),
/// no hang, no crash.
final class ActionLoopLiveTests: XCTestCase {

    private var keepAlive: [TempDir] = []

    private func analyzed() throws -> OrionDatabase {
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
        return db
    }

    func testRealQwen3DrivesRealToolsToAGroundedAnswer() async throws {
        guard ProcessInfo.processInfo.environment["ORION_AGENT_LIVE_MODEL_TEST"] == "1" else {
            throw XCTSkip(
                "Set ORION_AGENT_LIVE_MODEL_TEST=1 to run this test -- it downloads/loads the "
                    + "real Qwen3-8B-4bit weights and is not run in CI.")
        }

        let tools = QueryEngineTools.all(engine: QueryEngine(try analyzed()))
        let loop = ActionLoop(tools: tools, budget: 6)
        let agent = try await Qwen3Agent.load()
        let session = agent.makeSession(instructions: loop.instructions(context: nil))

        let start = ContinuousClock.now
        let answer = try await loop.run(
            question: "What does the Router class do? Use your tools to find out.",
            session: session)
        let elapsed = start.duration(to: .now)

        XCTAssertLessThan(elapsed, .seconds(60), "a real multi-turn investigation should not hang")
        XCTAssertFalse(answer.toolCalls.isEmpty, "expected at least one real tool call")
        XCTAssertTrue(
            answer.toolCalls.contains { $0.result.contains("Router") || $0.result.contains("dispatch") },
            "expected a tool call to have actually found the Router symbol")
    }
}
