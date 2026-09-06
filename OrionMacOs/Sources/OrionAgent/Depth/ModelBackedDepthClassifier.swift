import MLXLMCommon

/// **Superseded as `DepthModel`'s default fallback by `AppleFoundationDepthClassifier`** — kept
/// in the codebase because it's still directly tested and documents a real, reproducible bug
/// rather than being speculative: against real `Qwen3-8B-4bit`, this hung 10+ minutes on a
/// tool-calling classification call (reproduced on both a hard question and a trivial one once
/// tools were present), and neither `additionalContext: ["enable_thinking": false]` nor a
/// literal `/no_think` suffix fixed it for the tool-calling path specifically (both work fine
/// on plain chat). See Docs/12_phase3_mlx_agent.md Risk #3 for the full writeup. Retained for
/// potential reuse if `Qwen3Agent.collectStructuredCall` is ever needed again (e.g. M3's
/// structured answers) once that underlying mechanism is fixed or replaced.
///
/// Asks Qwen3 to report its routing decision as a `classify_depth` tool call rather than in
/// prose, via `Qwen3Agent.collectStructuredCall` — Docs/03 §3: explicit rules first, this only
/// runs when `DepthHeuristics` doesn't confidently match.
public struct ModelBackedDepthClassifier: DepthFallbackClassifying {
    private let agent: Qwen3Agent

    public init(agent: Qwen3Agent) {
        self.agent = agent
    }

    private static let instructions = """
        You are the routing component of a codebase-understanding agent. You do not answer the \
        developer's question yourself -- you only decide how much investigation it needs, then \
        report that decision by calling the classify_depth tool. Always call the tool; never \
        answer in prose.

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

    private struct DepthArgs: Codable, Sendable {
        let depth: Int
        let intent: String
        let confidence: String
        let rationale: String
    }

    public func classify(_ question: String) async throws -> DepthDecision {
        let args: DepthArgs? = try await agent.collectStructuredCall(
            to: question,
            instructions: Self.instructions,
            toolName: "classify_depth",
            toolDescription: "Report the routing depth for the developer's question.",
            parameters: [
                .required("depth", type: .int, description: "1, 2, or 3."),
                .required(
                    "intent", type: .string,
                    description:
                        "Short label for the kind of question, e.g. component_purpose, "
                        + "dependency_lookup, architectural_reasoning."),
                .required(
                    "confidence", type: .string,
                    description:
                        "\"high\", \"medium\", or \"low\" -- how sure you are this depth is sufficient."
                ),
                .required("rationale", type: .string, description: "One sentence explaining the choice."),
            ]
        )

        guard let args, let confidence = DepthConfidence(rawValue: args.confidence.lowercased())
        else {
            return DepthDecision(
                depth: 3, intent: "unclassified", confidence: .low,
                rationale: "Model did not return a valid classify_depth call.",
                method: .model
            )
        }
        let depth = min(max(args.depth, 1), 3)
        return DepthDecision(
            depth: depth, intent: args.intent, confidence: confidence, rationale: args.rationale,
            method: .model
        )
    }
}
