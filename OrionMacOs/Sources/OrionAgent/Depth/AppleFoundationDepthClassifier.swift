import FoundationModels

/// `@Generable` output shape for the depth-classification call -- Apple's real guided-generation
/// mechanism (`MODEL_CANDIDATES.md` §7 anticipated exactly this: "the eventual shipping app on
/// Apple Foundation Models would use `@Generable` guided generation").
@Generable
struct DepthClassificationOutput {
    let depth: Int
    let intent: String
    @Guide(.anyOf(["high", "medium", "low"]))
    let confidence: String
    let rationale: String
    /// Phase 5 guardrail (Docs/15 §3.2), added to this same call rather than a second one:
    /// `true` unless the question has nothing to do with the analyzed repository's code,
    /// structure, or behavior.
    let isRepositoryRelated: Bool
    /// Populated only when `isRepositoryRelated == false` -- the reason shown to the developer
    /// in place of an answer.
    let offTopicRationale: String
}

/// The Depth Model's fallback classifier, backed by Apple's on-device `SystemLanguageModel`
/// instead of `Qwen3Agent`'s tool-calling path.
///
/// **Why this replaced `ModelBackedDepthClassifier` as `DepthModel`'s default fallback.**
/// `ModelBackedDepthClassifier` (kept in the codebase, still tested, still documents a real
/// bug) hung 10+ minutes on real `Qwen3-8B-4bit` tool-calling calls and crashed the process on
/// timeout -- see that type's doc comment and Docs/12_phase3_mlx_agent.md Risk #3 for the full
/// story. `mlx-swift-lm` has no real constrained-decoding facility; Apple's `@Generable`/
/// `@Guide` is actual guided generation, backed by a small on-device model purpose-built for
/// fast structured classification rather than a "hybrid thinking" reasoning model -- the
/// opposite profile from what caused the hang. It also needs no MLX/Metal build workaround:
/// this compiles and runs under plain `swift build`/`swift test`, unlike anything touching
/// `mlx-swift-lm`.
public struct AppleFoundationDepthClassifier: DepthFallbackClassifying {
    private let repositoryName: String

    /// - Parameter repositoryName: a short identifier for the analyzed repository (e.g. its
    ///   checkout folder name) -- Docs/15_phase5_adaptive_exploration.md §11 M8's own real
    ///   finding: without this, the classifier has zero grounding in *which* repository is under
    ///   analysis, and a question that plainly names it ("What are the major components of
    ///   Starlette...") reads exactly like a request to recite general knowledge about a
    ///   same-named public library, not a request to investigate this specific analyzed
    ///   instance -- confirmed live as the root cause of two real false-declines in the
    ///   `PHASE5_ROUTING_BENCHMARK.md` 55-question run (`AR-01`, `AR-05`, both named "Starlette"
    ///   directly and were declined as "general knowledge" anyway). Defaults to `"the analyzed
    ///   repository"` so a caller that genuinely has no better identifier still gets a
    ///   grammatical instructions string, not a crash or an empty name.
    public init(repositoryName: String = "the analyzed repository") {
        self.repositoryName = repositoryName
    }

    private var instructions: String {
        """
        You are the routing component of a codebase-understanding agent, currently analyzing the \
        repository "\(repositoryName)". You do not answer the developer's question yourself -- \
        you only decide how much investigation it needs.

        depth 1: answerable from a short architecture summary alone (e.g. "what does X do", \
        "what is the responsibility of X").
        depth 2: needs one specific lookup against the indexed codebase (e.g. callers, tests, \
        module imports, dependents).
        depth 3: needs open-ended reasoning across multiple files or subsystems, or the \
        question is ambiguous.

        Set confidence to "low" or "medium" whenever you are not confident depth 1 or 2 is \
        sufficient -- an underconfident classification is escalated automatically, so it is \
        always safe to under-claim confidence rather than guess depth 3 outright.

        You must also judge whether the question is even about the analyzed repository at all.
        The repository you are routing questions for is "\(repositoryName)" -- a question that
        names it directly, or that says "this repository"/"this codebase"/"the app"/"this
        project", is about THIS specific analyzed instance and must be treated as in scope, even
        if the question's wording could also be read as a request for general knowledge about a
        same-named public library or a generic software-architecture explanation. Only treat a
        question as out of scope when it has nothing to do with \(repositoryName) at all. Set
        isRepositoryRelated to true for anything about \(repositoryName)'s code, structure,
        behavior, dependencies, tests, or Orion's own understanding of it (a meta-question like
        "what is this codebase model tracking" is still in scope -- it's about the tool's
        understanding of this repository). Set it to false only for general knowledge questions,
        chit-chat, or requests unrelated to understanding this specific repository.

        Examples:
        - "What are the major components of \(repositoryName), and how are they layered when \
        handling a request?" -> in scope (asks about this specific repository's real \
        architecture, not a generic software-architecture explanation).
        - "How does the WebSocket path diverge from the HTTP path in \(repositoryName)?" -> in \
        scope (a specific behavioral question about this repository).
        - "What's a good recipe for pasta?" -> out of scope.
        - "What does AuthService do?" -> in scope.

        When isRepositoryRelated is false, still fill in depth/intent/confidence with your best
        guess (they will be ignored) and put a short, honest reason in offTopicRationale (e.g.
        "This looks like a general knowledge question, not one about the analyzed repository.");
        otherwise leave offTopicRationale empty.
        """
    }

    public func classify(_ question: String) async throws -> DepthDecision {
        let model = SystemLanguageModel.default
        guard case .available = model.availability else {
            return DepthDecision(
                depth: 3, intent: "unclassified", confidence: .low,
                rationale:
                    "Apple Intelligence is unavailable on this device"
                    + " (\(model.availability)); escalated to Claude Code without attempting"
                    + " local classification.",
                method: .model
            )
        }

        let session = LanguageModelSession(instructions: Instructions(instructions))
        let response = try await session.respond(
            to: question, generating: DepthClassificationOutput.self)
        let output = response.content

        // Checked before the confidence field is even parsed (Docs/15 §3.2): a declined
        // classification's depth/confidence are the model's ignored best guess, not something
        // to validate as if they were going to be routed on.
        guard output.isRepositoryRelated else {
            return DepthDecision(
                depth: 3, intent: output.intent, confidence: .low,
                rationale:
                    output.offTopicRationale.isEmpty
                    ? "Judged unrelated to the analyzed repository." : output.offTopicRationale,
                method: .model, isInScope: false
            )
        }

        guard let confidence = DepthConfidence(rawValue: output.confidence.lowercased()) else {
            return DepthDecision(
                depth: 3, intent: output.intent, confidence: .low,
                rationale: "Model returned an unrecognized confidence value: \"\(output.confidence)\".",
                method: .model
            )
        }
        let depth = min(max(output.depth, 1), 3)
        return DepthDecision(
            depth: depth, intent: output.intent, confidence: confidence,
            rationale: output.rationale, method: .model
        )
    }
}
