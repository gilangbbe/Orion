import XCTest

@testable import OrionAgent

/// M0 smoke tests. Model-loading tests require a network download of `Qwen3-8B-4bit`
/// (~4.6GB) and are skipped unless `ORION_AGENT_LIVE_MODEL_TEST=1` is set -- the same posture
/// Phase 1 used for `npx`-gated SCIP tests and Phase 2 used for live `claude` CLI tests. See
/// Docs/12_phase3_mlx_agent.md's Testing & Verification section.
final class Qwen3AgentTests: XCTestCase {

    func testModelConfigurationPointsAtTheCommittedModel() {
        // No network/model load needed -- `ModelConfiguration.name` is resolved from the
        // static `.id` case alone. Confirms Docs/12's Decision #2 stays wired up correctly.
        XCTAssertEqual(Qwen3Agent.modelConfiguration.name, "mlx-community/Qwen3-8B-4bit")
    }

    func testLiveModelLoadsAndRespondsToATrivialPrompt() async throws {
        guard ProcessInfo.processInfo.environment["ORION_AGENT_LIVE_MODEL_TEST"] == "1" else {
            throw XCTSkip(
                "Set ORION_AGENT_LIVE_MODEL_TEST=1 to run this test -- it downloads/loads the "
                    + "real Qwen3-8B-4bit weights and is not run in CI.")
        }
        let agent = try await Qwen3Agent.load()
        let reply = try await agent.respond(to: "Reply with exactly one word: hello")
        XCTAssertFalse(reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
}
