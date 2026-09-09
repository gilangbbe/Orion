import Foundation
import OrionCodeIntel

/// Primes a local model with Phase 1/2's already-computed Code Graph before it reasons or
/// calls tools -- Docs/12 "Local execution & tool loop": the model should not have to
/// rediscover the repository structure from nothing, the way Claude's own prompt in
/// `ClaudeCodeInvestigator` points it at `code_graph.json` via the `Read` tool. Qwen3-8B has no
/// file-reading tool of its own here, so the export's content is embedded directly into the
/// session's instructions instead.
public enum ContextBuilder {
    /// Character budget per file/section -- keeps the primed context bounded regardless of repo
    /// size or session length; `code_graph.json` is already Phase 1's "compact skeleton for LLM
    /// context" (EXPORT.md), so truncation only bites on unusually large repos or, for a prior
    /// turn's answer (Docs/15 §4.3), an unusually long one.
    private static let maxCharsPerFile = 20_000

    /// `nil` when no export directory exists yet -- the caller still works, just with a colder
    /// start (Docs/12 Decision: Phase 3 depends on Phase 1/2 output but must not hard-fail
    /// without it during, e.g., `--force-depth 1` debugging against a freshly-created db).
    ///
    /// - Parameter priorTurns: this session's prior turns, oldest first (Docs/15 §4.3,
    ///   `Store.priorTurns` already bounds this to the most recent 5 and orders it this way --
    ///   this parameter does no bounding of its own). Empty for a session-less `ask()` call,
    ///   preserving this function's exact pre-Phase-5 output.
    /// - Parameter componentContext: a compact members/dependencies/claims block for a
    ///   component-scoped session (Docs/15 §4.3, built by the caller via
    ///   `ComponentDetailQuery.semanticDetail`) -- `nil` for a repository-scoped session or a
    ///   session-less call.
    public static func build(
        exportDir: URL, priorTurns: [AskSessionPriorTurn] = [], componentContext: String? = nil
    ) -> String? {
        var sections: [String] = []
        if let graph = readTruncated(exportDir.appendingPathComponent("code_graph.json")) {
            sections.append(
                "Code Graph (deterministically extracted, already fact-checked -- your map of "
                    + "the repository):\n\(graph)")
        }
        if let semantic = readTruncated(exportDir.appendingPathComponent("semantic_model.json")) {
            sections.append(
                "Semantic model (a prior investigation's components -- INTERPRETATION-tier, "
                    + "not fact):\n\(semantic)")
        }
        if let componentContext, !componentContext.isEmpty {
            sections.append(
                "This conversation is focused on one specific component:\n\(componentContext)")
        }
        if !priorTurns.isEmpty {
            let turnsText = priorTurns.map(formatted).joined(separator: "\n\n")
            sections.append(
                "Conversation so far in this session (oldest first -- treat this as established "
                    + "context, do not re-derive it from scratch):\n\(turnsText)")
        }
        guard !sections.isEmpty else { return nil }
        return sections.joined(separator: "\n\n")
    }

    private static func formatted(_ turn: AskSessionPriorTurn) -> String {
        let answer =
            turn.answerText.count > maxCharsPerFile
            ? String(turn.answerText.prefix(maxCharsPerFile)) + "\n...(truncated)" : turn.answerText
        return "Q: \(turn.question)\nA: \(answer)\n(outcome: \(turn.outcome))"
    }

    private static func readTruncated(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8)
        else { return nil }
        guard text.count > maxCharsPerFile else { return text }
        return String(text.prefix(maxCharsPerFile)) + "\n...(truncated)"
    }
}
