import Foundation

/// Primes a local model with Phase 1/2's already-computed Code Graph before it reasons or
/// calls tools -- Docs/12 "Local execution & tool loop": the model should not have to
/// rediscover the repository structure from nothing, the way Claude's own prompt in
/// `ClaudeCodeInvestigator` points it at `code_graph.json` via the `Read` tool. Qwen3-8B has no
/// file-reading tool of its own here, so the export's content is embedded directly into the
/// session's instructions instead.
public enum ContextBuilder {
    /// Character budget per file -- keeps the primed context bounded regardless of repo size;
    /// `code_graph.json` is already Phase 1's "compact skeleton for LLM context" (EXPORT.md),
    /// so truncation only bites on unusually large repos.
    private static let maxCharsPerFile = 20_000

    /// `nil` when no export directory exists yet -- the caller still works, just with a colder
    /// start (Docs/12 Decision: Phase 3 depends on Phase 1/2 output but must not hard-fail
    /// without it during, e.g., `--force-depth 1` debugging against a freshly-created db).
    public static func build(exportDir: URL) -> String? {
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
        guard !sections.isEmpty else { return nil }
        return sections.joined(separator: "\n\n")
    }

    private static func readTruncated(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8)
        else { return nil }
        guard text.count > maxCharsPerFile else { return text }
        return String(text.prefix(maxCharsPerFile)) + "\n...(truncated)"
    }
}
