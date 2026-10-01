import Foundation
import FoundationModels
import OrionCore

/// The on-device system model as an Orion backend (`LocalModelBackend.system`, Docs/19 M1) -- the
/// only model on iOS, and a development convenience on the Mac.
public enum SystemModelInfo {
    /// `SystemLanguageModel.default.variant.displayName`, e.g. "AFM 3 Core". Reading it doesn't
    /// load the model.
    public static var variantName: String { SystemLanguageModel.default.variant.displayName }

    /// Its context window in tokens: 4,096 on iPhone 17, 8,192 on the Mac (Docs/19 M0).
    public static var contextSize: Int { SystemLanguageModel.default.contextSize }

    /// Whether the model can run on this device right now, and if not, why.
    public static var availability: SystemLanguageModel.Availability { SystemLanguageModel.default.availability }

    /// Generation settings for the system model. The Core AI defaults don't fit: their 8,192-token
    /// reply cap is the iPhone's whole window twice over. Sampling is left at the model's own
    /// default rather than Qwen's temperature 0.6.
    public static let options = GenerationOptions(maximumResponseTokens: replyTokens)

    /// The longest answer the system model may write. Part of every Ask's token budget, so it's
    /// kept to what a phone screen reads comfortably (Docs/19 M6).
    public static let replyTokens = 512

    /// An `AgentModel` over the system model.
    public static func agent(options: GenerationOptions = options) -> FoundationModelsAgent<SystemLanguageModel> {
        FoundationModelsAgent(
            model: SystemLanguageModel.default, modelIdentifier: LocalModelBackend.system.modelIdentifier,
            options: options)
    }
}

/// Ask on the system model (Docs/19 M6): the iPhone's whole configuration, in one place so the
/// app and `orion-agent ask --local-backend system` run the same path.
///
/// - Context: `CompactContextBuilder`, budgeted from the model's own `contextSize` minus what it
///   measures (`tokenCount`) for the instructions, the tool schemas and the question, minus room
///   for the reply and for every allowed tool result. On the retry after `contextSizeExceeded`,
///   half that.
/// - Tools: `SnapshotTools`, each result capped at `toolResultCharLimit`, at most `toolBudget`
///   calls.
public enum SystemModelAsk {
    public static let toolBudget = 3
    public static let toolResultCharLimit = 900
    /// Slack for the chat template's own framing tokens.
    static let marginTokens = 96

    public static func session(config: AgentSessionConfig) -> AgentSession {
        var config = config
        config.localBackend = .system
        config.toolBudget = toolBudget
        config.canDelegate = false
        return AgentSession(
            config: config,
            contextProvider: { request in try await context(for: request) },
            toolsProvider: { store, run in SnapshotTools.all(store: store, run: run) },
            toolResultCharLimit: toolResultCharLimit)
    }

    /// The token budget left for primed context, and the context packed into it.
    public static func context(for request: ContextRequest) async throws -> String {
        let model = SystemLanguageModel.default
        let fixed = try await model.tokenCount(for: Instructions(request.baseInstructions))
            + (request.tools.isEmpty ? 0 : try await model.tokenCount(for: request.tools))
            + model.tokenCount(for: request.question)
        let toolResults = request.tools.isEmpty ? 0 : toolBudget * (toolResultCharLimit / 4)
        var budget = model.contextSize - fixed - SystemModelInfo.replyTokens - toolResults - marginTokens
        if request.attempt > 0 { budget /= 2 }
        return try await CompactContextBuilder.build(
            store: request.store, run: request.run, question: request.question, priorTurns: request.priorTurns,
            componentContext: request.componentContext, budgetTokens: max(budget, 0),
            countTokens: { try await model.tokenCount(for: $0) })
    }
}

/// Teaching on the system model (Docs/19 M7): the iPhone's drafter and judge, in one place so the
/// app and `orion-agent teach bench --local-backend system --judge-output single` run the same
/// configuration.
public enum SystemModelTeaching {
    /// The longest draft: a question, a 120-word reference answer and up to eight rubric points
    /// fit in about 600 tokens (Docs/19 M7).
    public static let draftReplyTokens = 1_000

    /// Judge votes per criterion. `RubricGrader`'s default is 3, but on the iPhone k = 3 took 3.3×
    /// as long and agreed with the expert less (κ 0.60 vs 0.69, Docs/19 M7) -- and with greedy
    /// decoding a second vote would only repeat the first.
    public static let judgeVotes = 1

    /// Greedy: the same answer should get the same grade, not a fresh draw (the skill: prefer
    /// `.greedy` for strict `@Generable` output). On the iPhone's gold set it measured κ 0.62,
    /// against 0.69 for one sampled run (Docs/19 M7).
    public static let judgeOptions = GenerationOptions(samplingMode: .greedy, maximumResponseTokens: SystemModelInfo.replyTokens)

    /// Writes the question rows and attempts as `device`, so a re-import carries them (Docs/19 M3).
    public static func judge() -> any CriterionJudging {
        SingleCallCriterionJudge(model: SystemModelInfo.agent(options: judgeOptions), source: .device)
    }

    public static func drafter() -> GuidedTeachingDrafter {
        let model = SystemLanguageModel.default
        return GuidedTeachingDrafter(
            source: .device,
            inputBudget: model.contextSize - draftReplyTokens - SystemModelAsk.marginTokens,
            countTokens: { instructions, prompt, schema in
                try await model.tokenCount(for: Instructions(instructions))
                    + model.tokenCount(for: prompt)
                    + model.tokenCount(for: schema)
            },
            respond: { instructions, prompt, schema in
                let session = LanguageModelSession(model: model, instructions: instructions)
                return try await session.respond(
                    to: prompt, schema: schema, options: GenerationOptions(maximumResponseTokens: draftReplyTokens)
                ).content
            })
    }
}
