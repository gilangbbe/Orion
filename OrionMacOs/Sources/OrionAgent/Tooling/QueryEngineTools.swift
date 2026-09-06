import OrionCodeIntel

/// The four `AgentTool`s over Phase 1's `QueryEngine` -- no new deterministic capability, just
/// agent-callable wrappers over what Phase 1 already computed (Docs/12 "Tools").
public enum QueryEngineTools {
    /// All four tools, ready to hand to an `ActionLoop`.
    public static func all(engine: QueryEngine, commit: String? = nil) -> [AgentTool] {
        [
            LookupSymbolTool(engine: engine, commit: commit),
            ModuleSymbolsTool(engine: engine, commit: commit),
            CallersTool(engine: engine, commit: commit),
            CalleesTool(engine: engine, commit: commit),
        ]
    }
}

private let defaultLimit = 10

public struct LookupSymbolTool: AgentTool {
    let engine: QueryEngine
    let commit: String?

    public let name = "lookup_symbol"
    public let description =
        "Find symbols whose anchor or qualified name contains a substring. "
        + "Arguments: {\"query\": \"<substring>\"}"

    public func execute(arguments: [String: Any]) -> String {
        guard let query = arguments["query"] as? String, !query.isEmpty else {
            return "Error: lookup_symbol requires a non-empty \"query\" argument."
        }
        guard let hits = try? engine.findSymbols(matching: query, commit: commit, limit: defaultLimit),
            !hits.isEmpty
        else {
            return "No symbols found matching \"\(query)\"."
        }
        return hits.map { "\($0.anchor) (\($0.kind)) — \($0.file):\($0.startLine)-\($0.endLine)" }
            .joined(separator: "\n")
    }
}

public struct ModuleSymbolsTool: AgentTool {
    let engine: QueryEngine
    let commit: String?

    public let name = "module_symbols"
    public let description =
        "List the symbols defined in a module by its dotted module path. "
        + "Arguments: {\"module\": \"<dotted.module.path>\"}"

    public func execute(arguments: [String: Any]) -> String {
        guard let module = arguments["module"] as? String, !module.isEmpty else {
            return "Error: module_symbols requires a non-empty \"module\" argument."
        }
        guard
            let hits = try? engine.moduleSymbols(module, commit: commit, limit: defaultLimit * 3),
            !hits.isEmpty
        else {
            return "No module found at \"\(module)\"."
        }
        return hits.map { "\($0.anchor) (\($0.kind))" }.joined(separator: "\n")
    }
}

public struct CallersTool: AgentTool {
    let engine: QueryEngine
    let commit: String?

    public let name = "callers"
    public let description =
        "List what points at a symbol (imports it, calls it, extends it, etc.), by its exact "
        + "anchor. Arguments: {\"anchor\": \"<path::Dotted.Name>\"}"

    public func execute(arguments: [String: Any]) -> String {
        guard let anchor = arguments["anchor"] as? String, !anchor.isEmpty else {
            return "Error: callers requires a non-empty \"anchor\" argument."
        }
        guard let hits = try? engine.callers(of: anchor, commit: commit, limit: defaultLimit),
            !hits.isEmpty
        else {
            return "No callers found for \"\(anchor)\"."
        }
        return hits.map { "\($0.type): \($0.anchor ?? $0.ref ?? "?")" }.joined(separator: "\n")
    }
}

public struct CalleesTool: AgentTool {
    let engine: QueryEngine
    let commit: String?

    public let name = "callees"
    public let description =
        "List what a symbol points at (imports, calls, extends, etc.), by its exact anchor. "
        + "Arguments: {\"anchor\": \"<path::Dotted.Name>\"}"

    public func execute(arguments: [String: Any]) -> String {
        guard let anchor = arguments["anchor"] as? String, !anchor.isEmpty else {
            return "Error: callees requires a non-empty \"anchor\" argument."
        }
        guard let hits = try? engine.callees(of: anchor, commit: commit, limit: defaultLimit),
            !hits.isEmpty
        else {
            return "\"\(anchor)\" has no outbound edges on record."
        }
        return hits.map { "\($0.type): \($0.anchor ?? $0.ref ?? "?")" }.joined(separator: "\n")
    }
}
