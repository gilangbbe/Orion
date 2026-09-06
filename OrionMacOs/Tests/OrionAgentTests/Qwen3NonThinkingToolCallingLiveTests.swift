import XCTest
import HuggingFace
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import Tokenizers

@testable import OrionAgent

/// M2 exploration (Docs/12_phase3_mlx_agent.md Risk #3, option (b)): does a Qwen3 checkpoint
/// that is explicitly *not* hybrid-thinking fix the `mlx-swift-lm` tool-calling hang that
/// `ModelBackedDepthClassifier` hit on `Qwen3-8B-4bit`? `MODEL_CANDIDATES.md` lists
/// `Qwen3-4B-Instruct-2507` as explicitly non-thinking, unlike the base `Qwen3-8B`/`Qwen3-4B`
/// checkpoints. Deliberately isolated from `Qwen3Agent` (production code) -- this is a
/// standalone experiment, not yet a design decision, so it duplicates just enough of
/// `collectStructuredCall`'s shape inline rather than generalizing production code for a model
/// that might not be adopted.
///
/// **Confirmed live, twice: yes, this fixes it.** ~2.0-2.1s per tool call, correct
/// `classify_depth` arguments both times, no hang, no crash -- originally reproduced via a
/// temporary CLI command since `xcodebuild test` doesn't honor this test's env var; this test
/// itself was later confirmed runnable directly (see the runner note below), so the CLI
/// experiment was removed after recording the result.
///
/// **Testing-infrastructure gap, found then resolved the same session**: MLX-touching live
/// tests can't run under plain `swift test` (can't build the Metal shaders MLX needs at
/// runtime) or `xcodebuild test` (doesn't propagate env vars exported in the invoking shell to
/// the test host). The fix: `xcodebuild build-for-testing` (builds the `.xctest` bundle with
/// Metal shaders, same as a normal build) then run it directly with `xcrun xctest`, which *does*
/// inherit the invoking shell's environment:
/// ```
/// xcodebuild build-for-testing -scheme OrionCodeIntel-Package -destination 'platform=macOS' \
///   -derivedDataPath /tmp/orion-xcodebuild -skipPackagePluginValidation -skipMacroValidation
/// ORION_AGENT_LIVE_MODEL_TEST=1 xcrun xctest \
///   -XCTest OrionAgentTests.Qwen3NonThinkingToolCallingLiveTests/testNonThinkingModelToolCallCompletesQuickly \
///   /tmp/orion-xcodebuild/Build/Products/Debug/OrionAgentTests.xctest
/// ```
/// Confirmed live for this test and for `ActionLoopLiveTests`/`Qwen3AgentTests` in M2 -- this
/// is now the documented way to run any MLX-touching live test, not a per-test workaround.
final class Qwen3NonThinkingToolCallingLiveTests: XCTestCase {

    private static let nonThinkingConfiguration = ModelConfiguration(
        id: "mlx-community/Qwen3-4B-Instruct-2507-4bit")

    struct ToolAck: Codable, Sendable {}

    struct DepthArgs: Codable, Sendable {
        let depth: Int
        let intent: String
        let confidence: String
        let rationale: String
    }

    func testNonThinkingModelToolCallCompletesQuickly() async throws {
        guard ProcessInfo.processInfo.environment["ORION_AGENT_LIVE_MODEL_TEST"] == "1" else {
            throw XCTSkip(
                "Set ORION_AGENT_LIVE_MODEL_TEST=1 to run this test -- it downloads/loads real "
                    + "Qwen3-4B-Instruct-2507-4bit weights (~2.3GB) and is not run in CI.")
        }

        let container = try await LLMModelFactory.shared.loadContainer(
            from: #hubDownloader(),
            using: #huggingFaceTokenizerLoader(),
            configuration: Self.nonThinkingConfiguration
        )

        let captured = CapturedValue<DepthArgs>()
        let tool = Tool<DepthArgs, ToolAck>(
            name: "classify_depth",
            description: "Report the routing depth for the developer's question.",
            parameters: [
                .required("depth", type: .int, description: "1, 2, or 3."),
                .required("intent", type: .string, description: "Short label for the kind of question."),
                .required(
                    "confidence", type: .string,
                    description: "\"high\", \"medium\", or \"low\"."),
                .required("rationale", type: .string, description: "One sentence explaining the choice."),
            ]
        ) { input in
            await captured.set(input)
            return ToolAck()
        }

        let session = ChatSession(
            container,
            instructions:
                "You are the routing component of a codebase-understanding agent. Always answer "
                + "by calling the classify_depth tool -- never answer in prose.",
            tools: [tool.schema],
            toolDispatch: { call in
                guard call.function.name == tool.name else {
                    return "Error: no such tool \"\(call.function.name)\"."
                }
                _ = try await call.execute(with: tool)
                return "ok"
            }
        )

        let start = ContinuousClock.now
        _ = try await session.respond(
            to: "Why was the authentication architecture designed this way, and what would "
                + "break if the session storage backend were swapped out?")
        let elapsed = start.duration(to: .now)

        XCTAssertLessThan(
            elapsed, .seconds(60),
            "non-thinking checkpoint should not reproduce Qwen3-8B's multi-minute hang")
        let args = await captured.value
        XCTAssertNotNil(args, "expected the model to call classify_depth at all")
        if let args {
            XCTAssertTrue((1...3).contains(args.depth))
        }
    }
}
