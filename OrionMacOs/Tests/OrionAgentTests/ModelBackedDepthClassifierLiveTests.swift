import XCTest

@testable import OrionAgent

/// Live-model coverage for the tool-call-based structured fallback classifier. Same posture as
/// `Qwen3AgentTests`: requires `ORION_AGENT_LIVE_MODEL_TEST=1`, downloads/loads real weights,
/// not run in CI.
///
/// **This is the concrete check for Docs/12_phase3_mlx_agent.md Risk #3, and it found a real
/// problem.** `ModelBackedDepthClassifier.classify` alone (not through `DepthModel`) hung past
/// 10 minutes of continuous generation with zero output against real `Qwen3-8B-4bit` -- on a
/// hard question and, once tools were in play, on a trivial one too. Neither
/// `additionalContext: ["enable_thinking": false]` nor a literal `/no_think` suffix fixed it
/// for the tool-calling path specifically, though both work on the plain-chat path. Routed
/// through `DepthModel` instead (as it always is in real use), the hang is bounded and
/// escalates to depth 3 -- that's what this test actually exercises, with a short timeout so
/// the test itself finishes quickly rather than reproducing the multi-minute hang directly.
final class ModelBackedDepthClassifierLiveTests: XCTestCase {

    func testHungClassifierEscalatesToDepth3ThroughDepthModel() async throws {
        guard ProcessInfo.processInfo.environment["ORION_AGENT_LIVE_MODEL_TEST"] == "1" else {
            throw XCTSkip(
                "Set ORION_AGENT_LIVE_MODEL_TEST=1 to run this test -- it downloads/loads the "
                    + "real Qwen3-8B-4bit weights and is not run in CI.")
        }
        let agent = try await Qwen3Agent.load()
        let model = DepthModel(
            fallback: ModelBackedDepthClassifier(agent: agent), fallbackTimeout: .seconds(15))
        // A trivial question, on purpose: M1's live testing found the hang independent of
        // question difficulty once a tool schema is offered, so this is the cheapest
        // reproduction, not a synthetic worst case.
        let decision = try await model.classify("In one word, what color is the sky?")
        XCTAssertEqual(
            decision.depth, 3,
            "expected the known-hung fallback to be timed out and escalated, not answered")
    }
}
