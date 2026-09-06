import Foundation
import HuggingFace
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import Tokenizers

/// Wraps `mlx-community/Qwen3-8B-4bit` via `mlx-swift-lm`'s `ModelContainer` + `ChatSession`.
///
/// Loading downloads the model's weights (~4.6GB, per Task 3's measurement of the same
/// checkpoint under `mlx-lm`) through the Hugging Face Hub client on first use -- construction
/// is async, requires network the first time, and is cached by the Hub client afterwards. See
/// Docs/12_phase3_mlx_agent.md M0.
public final class Qwen3Agent: AgentModel {
    /// `mlx-community/Qwen3-8B-4bit` -- see Docs/12_phase3_mlx_agent.md Decision #2.
    public static let modelConfiguration = LLMRegistry.qwen3_8b_4bit

    private let container: ModelContainer

    private init(container: ModelContainer) {
        self.container = container
    }

    /// Loads the model, downloading weights via the Hugging Face Hub if not already cached.
    public static func load(
        progressHandler: @Sendable @escaping (Progress) -> Void = { _ in }
    ) async throws -> Qwen3Agent {
        let container = try await LLMModelFactory.shared.loadContainer(
            from: #hubDownloader(),
            using: #huggingFaceTokenizerLoader(),
            configuration: modelConfiguration,
            progressHandler: progressHandler
        )
        return Qwen3Agent(container: container)
    }

    public func respond(to message: String, instructions: String? = nil) async throws -> String {
        let session = ChatSession(container, instructions: instructions)
        return try await session.respond(to: message)
    }

    /// A fresh multi-turn session for `ActionLoop` (Docs/12 "Local execution & tool loop") --
    /// plain-chat only, no `tools`/`toolDispatch` configured. Returned as `any TurnGenerating`
    /// so callers (and tests) don't need to import `MLXLMCommon` just to drive the loop.
    public func makeSession(instructions: String?) -> any TurnGenerating {
        ChatSession(container, instructions: instructions)
    }

    /// Runs one exchange where `tool` (the *only* tool offered) is how the model is expected to
    /// answer -- not in prose. Returns the decoded arguments of the first call to it, or `nil`
    /// if the model replied without calling it at all. `mlx-swift-lm` has no
    /// constrained/guided-generation facility (confirmed at M0 -- see
    /// Docs/12_phase3_mlx_agent.md's Dependency section); this reuses its native tool-calling
    /// path as the structured-output mechanism instead, first for the Depth Model's fallback
    /// classifier and later, in M3, for Claude-delegation-free structured answers too.
    ///
    /// A `nil` result is a real, surfaceable signal (the model didn't do what it was asked),
    /// not swallowed here -- see Docs/12 Risk #3 on unverified tool-call reliability.
    ///
    /// **Suppressing Qwen3's hybrid thinking is load-bearing, not cosmetic.** Verified live at
    /// M1: without it, Qwen3-8B's chat template generates an extended `<think>...</think>`
    /// reasoning trace before ever emitting the tool call -- confirmed to run past 10 minutes
    /// of continuous generation, with zero output, on both a genuinely hard question *and* a
    /// trivial one ("what color is the sky") once tools were present. Passing
    /// `additionalContext: ["enable_thinking": false]` alone (the mechanism
    /// `mlx-swift-lm`'s own `IntegrationTestHelpers` use in its tool-calling tests) did **not**
    /// fix this for tool-calling sessions on this checkpoint when tested live -- reproduced
    /// twice. What did work, verified live: appending the literal `/no_think` suffix Qwen3's
    /// own template recognizes directly in the message text (1.7s round trip on the plain-chat
    /// path vs. 10+ minutes without it). Kept `enable_thinking: false` alongside it since it's
    /// documented and harmless, but `/no_think` is the mechanism actually carrying the fix.
    public func collectStructuredCall<Input: Codable & Sendable>(
        to message: String,
        instructions: String?,
        toolName: String,
        toolDescription: String,
        parameters: [ToolParameter]
    ) async throws -> Input? {
        let captured = CapturedValue<Input>()
        let tool = Tool<Input, ToolAck>(
            name: toolName, description: toolDescription, parameters: parameters
        ) { input in
            await captured.set(input)
            return ToolAck()
        }
        let session = ChatSession(
            container,
            instructions: instructions,
            additionalContext: ["enable_thinking": false],
            tools: [tool.schema],
            toolDispatch: { call in
                guard call.function.name == tool.name else {
                    return "Error: no such tool \"\(call.function.name)\"."
                }
                _ = try await call.execute(with: tool)
                return "ok"
            }
        )
        _ = try await session.respond(to: "\(message) /no_think")
        return await captured.value
    }
}
