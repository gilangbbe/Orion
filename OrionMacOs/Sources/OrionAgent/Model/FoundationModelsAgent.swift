import FoundationModels

/// Generation settings for every FoundationModels-backed local call (Docs/18 M2).
public enum LocalGenerationDefaults {
    /// Temperature 0.6 is what the MLX path ran with (`mlx-swift-lm`'s defaults), kept so Docs/18
    /// M3's MLX-vs-Core AI comparison changed the runtime, not the sampling. The cap is explicit because a `nil`
    /// `maximumResponseTokens` makes `CoreAILanguageModel` fall back to 2048 for a reasoning
    /// model, which a long Qwen3 `<think>` trace can exhaust before the answer starts.
    public static let options = GenerationOptions(temperature: 0.6, maximumResponseTokens: 8192)
}

/// `AgentModel` over any FoundationModels `LanguageModel` -- in practice `CoreAILanguageModel`
/// (Docs/18 M2), but generic so tests can drive it with an offline custom provider.
///
/// A reasoning model's thinking arrives as transcript reasoning entries, not in `.content`, so
/// the answer text never contains `<think>`.
public final class FoundationModelsAgent<Model: LanguageModel>: AgentModel {
    public let modelIdentifier: String
    private let model: Model
    private let options: GenerationOptions
    /// Carries the role's reasoning level (Docs/18 M4); the default leaves thinking on.
    private let contextOptions: ContextOptions

    public init(
        model: Model, modelIdentifier: String, options: GenerationOptions = LocalGenerationDefaults.options,
        contextOptions: ContextOptions = ContextOptions()
    ) {
        self.model = model
        self.modelIdentifier = modelIdentifier
        self.options = options
        self.contextOptions = contextOptions
    }

    /// The same loaded model under different context options -- how `LocalModelLoader` serves a
    /// non-thinking role without loading the weights twice.
    public func with(contextOptions: ContextOptions, modelIdentifier: String) -> FoundationModelsAgent {
        FoundationModelsAgent(
            model: model, modelIdentifier: modelIdentifier, options: options, contextOptions: contextOptions)
    }

    public func respond(to message: String, instructions: String?) async throws -> String {
        let session = LanguageModelSession(model: model, instructions: instructions)
        return try await session.respond(to: message, options: options, contextOptions: contextOptions).content
    }

    public func makeSession(instructions: String?) -> any TurnGenerating {
        FoundationModelsTurnSession(
            session: LanguageModelSession(model: model, instructions: instructions), options: options,
            contextOptions: contextOptions)
    }
}

extension FoundationModelsAgent: NativeToolCallingModel {
    public func makeToolSession(tools: [any Tool], instructions: String?) -> any ToolCallingTurnGenerating {
        FoundationModelsToolSession(
            session: LanguageModelSession(model: model, tools: tools, instructions: instructions),
            options: options, contextOptions: contextOptions)
    }
}

extension FoundationModelsAgent: GuidedGenerating {
    public func makeGuidedSession(instructions: String?) -> any GuidedTurnGenerating {
        FoundationModelsGuidedSession(
            session: LanguageModelSession(model: model, instructions: instructions), options: options)
    }
}

/// One `LanguageModelSession` whose turns are generated into schemas. Always without thinking:
/// constrained decoding applies the schema's grammar from the first token, so a thinking chat
/// template would open a `<think>` block the grammar can't allow (Docs/18 M5).
final class FoundationModelsGuidedSession: GuidedTurnGenerating {
    static let contextOptions = ContextOptions(includeSchemaInPrompt: true, reasoningLevel: .custom("none"))
    /// A schema's string fields are free text inside the grammar; the cap stops one that never
    /// closes (a quote copying the answer over and over) from running to the 8192-token default.
    /// A turn that hits it throws, which `RubricGrader` counts as one unconfident vote.
    static let maximumResponseTokens = 512
    private let session: LanguageModelSession
    private let options: GenerationOptions

    init(session: LanguageModelSession, options: GenerationOptions) {
        self.session = session
        var capped = options
        capped.maximumResponseTokens = min(options.maximumResponseTokens ?? Self.maximumResponseTokens, Self.maximumResponseTokens)
        self.options = capped
    }

    func respond<Content: Generable>(to message: String, generating type: Content.Type) async throws -> Content {
        try await session.respond(
            to: message, generating: type, options: options, contextOptions: Self.contextOptions
        ).content
    }
}

extension FoundationModelsAgent: RuntimeBenchmarking {
    /// `RuntimeBenchmarking` (Docs/18 M3). Greedy via `samplingMode`, thinking off via
    /// `reasoningLevel .custom("none")` -- `CoreAILanguageModel` maps that to the chat template's
    /// `enable_thinking: false`.
    public func benchmarkTurns(_ prompts: [String], maxTokens: Int) async throws -> [RuntimeSample] {
        let session = LanguageModelSession(model: model)
        let options = GenerationOptions(samplingMode: .greedy, maximumResponseTokens: maxTokens)
        let context = ContextOptions(reasoningLevel: .custom("none"))
        var samples: [RuntimeSample] = []
        for prompt in prompts {
            let start = ContinuousClock.now
            var firstChunk: Duration?
            var usage: LanguageModelSession.Usage?
            for try await snapshot in session.streamResponse(to: prompt, options: options, contextOptions: context) {
                if firstChunk == nil, !snapshot.content.isEmpty { firstChunk = start.duration(to: .now) }
                usage = snapshot.usage
            }
            let total = start.duration(to: .now)
            samples.append(RuntimeSample(
                promptTokens: usage?.input.totalTokenCount ?? 0, outputTokens: usage?.output.totalTokenCount ?? 0,
                ttftMs: (firstChunk ?? total).milliseconds, totalMs: total.milliseconds))
        }
        return samples
    }
}

/// One plain-chat `LanguageModelSession`, turn by turn (depth 1). A wrapper rather than a
/// `TurnGenerating` conformance on `LanguageModelSession` itself, whose own `respond(to:)`
/// overloads would make that conformance ambiguous.
final class FoundationModelsTurnSession: TurnGenerating {
    private let session: LanguageModelSession
    private let options: GenerationOptions
    private let contextOptions: ContextOptions

    init(session: LanguageModelSession, options: GenerationOptions, contextOptions: ContextOptions) {
        self.session = session
        self.options = options
        self.contextOptions = contextOptions
    }

    func respond(to message: String) async throws -> String {
        try await session.respond(to: message, options: options, contextOptions: contextOptions).content
    }
}

/// One `LanguageModelSession` with tools, driven by `NativeToolLoop`. The session runs each
/// turn's tool calls itself; a tool-free turn sets `toolCallingMode` to `.disallowed`.
final class FoundationModelsToolSession: ToolCallingTurnGenerating {
    let session: LanguageModelSession
    private let options: GenerationOptions
    private let contextOptions: ContextOptions

    init(session: LanguageModelSession, options: GenerationOptions, contextOptions: ContextOptions) {
        self.session = session
        self.options = options
        self.contextOptions = contextOptions
    }

    func respond(to message: String, toolsAllowed: Bool) async throws -> String {
        var turnOptions = options
        if !toolsAllowed { turnOptions.toolCallingMode = .disallowed }
        return try await session.respond(to: message, options: turnOptions, contextOptions: contextOptions).content
    }
}
