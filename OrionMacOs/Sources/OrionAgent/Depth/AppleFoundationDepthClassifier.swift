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
    public init() {}

    private static let instructions = """
        You are the routing component of a codebase-understanding agent. You do not answer the \
        developer's question yourself -- you only decide how much investigation it needs.

        depth 1: answerable from a short architecture summary alone (e.g. "what does X do", \
        "what is the responsibility of X").
        depth 2: needs one specific lookup against the indexed codebase (e.g. callers, tests, \
        module imports, dependents).
        depth 3: needs open-ended reasoning across multiple files or subsystems, or the \
        question is ambiguous.

        Set confidence to "low" or "medium" whenever you are not confident depth 1 or 2 is \
        sufficient -- an underconfident classification is escalated automatically, so it is \
        always safe to under-claim confidence rather than guess depth 3 outright.
        """

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

        let session = LanguageModelSession(instructions: Instructions(Self.instructions))
        let response = try await session.respond(
            to: question, generating: DepthClassificationOutput.self)
        let output = response.content

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
