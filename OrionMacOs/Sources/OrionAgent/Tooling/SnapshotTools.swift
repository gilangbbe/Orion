import Foundation
import OrionCore

/// The iPhone's tool set (Docs/19 M6). Every tool's schema costs context on a 4,096-token model
/// (the Foundation Models skill: "limit tools"), so the phone gets four, not the Mac's four plus
/// more:
///
/// - `lookup_symbol` and `callers` -- the Mac's own `QueryEngineTools`.
/// - `symbol_details` -- one symbol's signature, docstring and, when the snapshot carries it,
///   its code (`evidence_snippets`). The phone has no checkout, so this is how the model reads
///   code at all.
/// - `search_claims` -- checked claims mentioning given words: the semantic model is the phone's
///   richest knowledge, and `CompactContextBuilder` can only prime a few claims.
///
/// `module_symbols` and `callees` are left out: `lookup_symbol` covers most of the first, and the
/// second is rarely what a question needs.
public enum SnapshotTools {
    public static func all(store: Store, run: AnalysisRunRecord) -> [AgentTool] {
        let engine = QueryEngine(store.db)
        return [
            LookupSymbolTool(engine: engine, commit: run.commitHash),
            SymbolDetailsTool(store: store, engine: engine, run: run),
            CallersTool(engine: engine, commit: run.commitHash),
            SearchClaimsTool(store: store, run: run),
        ]
    }
}

public struct SymbolDetailsTool: AgentTool {
    let store: Store
    let engine: QueryEngine
    let run: AnalysisRunRecord

    public let name = "symbol_details"
    public let description = "Read one symbol: its signature, docstring and, when available, its code."
    public let parameters = [
        AgentToolParameter(
            name: "anchor", description: "A symbol's anchor from lookup_symbol, e.g. \"pkg/module.py::Class.method\", or just its name.")
    ]

    /// Lines of code returned at most -- a long function's head is what a question needs.
    static let maxCodeLines = 30

    /// A bare name ("Router") is a substring of file paths too (`pkg/router.py`), so prefer the
    /// symbol actually named that, then any non-module hit, then whatever matched first.
    static func bestMatch(for query: String, in hits: [QueryEngine.SymbolHit]) -> QueryEngine.SymbolHit? {
        let lower = query.lowercased()
        return hits.first { $0.anchor.lowercased().hasSuffix("::\(lower)") || $0.anchor.lowercased().hasSuffix(".\(lower)") }
            ?? hits.first { $0.kind != "module" && $0.kind != "package" }
            ?? hits.first
    }

    public func execute(arguments: [String: Any]) -> String {
        guard let query = (arguments["anchor"] as? String)?.trimmingCharacters(in: .whitespaces), !query.isEmpty else {
            return "Error: symbol_details requires a non-empty \"anchor\" argument."
        }
        let symbol: SymbolRecord?
        if let exact = try? store.symbol(runId: run.id, anchor: query) {
            symbol = exact
        } else if let hit = Self.bestMatch(
            for: query, in: (try? engine.findSymbols(matching: query, commit: run.commitHash, limit: 20)) ?? [])
        {
            symbol = try? store.symbol(runId: run.id, anchor: hit.anchor)
        } else {
            symbol = nil
        }
        guard let symbol else { return "No symbol found for \"\(query)\". Try lookup_symbol first." }

        var lines = ["\(symbol.anchor) (\(symbol.kind)) lines \(symbol.startLine)-\(symbol.endLine)"]
        if let signature = symbol.signature { lines.append("Signature: \(signature)") }
        if let docstring = symbol.docstring {
            lines.append("Docstring: " + docstring.split(separator: "\n").prefix(4).joined(separator: " "))
        }
        if let slice = try? store.evidenceSlice(anchor: symbol.anchor, startLine: symbol.startLine, endLine: symbol.endLine) {
            let code = slice.lines.prefix(Self.maxCodeLines).joined(separator: "\n")
            lines.append("Code (from line \(slice.firstLine)):\n\(code)")
        } else {
            lines.append("(Its code isn't on this device; only cited code is synced.)")
        }
        return lines.joined(separator: "\n")
    }
}

public struct SearchClaimsTool: AgentTool {
    let store: Store
    let run: AnalysisRunRecord

    public let name = "search_claims"
    public let description = "Find checked statements about the codebase that mention given words."
    public let parameters = [
        AgentToolParameter(name: "words", description: "A few words to search for, e.g. \"middleware order\".")
    ]

    static let limit = 5

    public func execute(arguments: [String: Any]) -> String {
        guard let words = (arguments["words"] as? String), !words.isEmpty else {
            return "Error: search_claims requires a non-empty \"words\" argument."
        }
        let terms = CompactContextBuilder.terms(words)
        guard !terms.isEmpty else { return "No claims mention \"\(words)\"." }
        var scored: [(Double, String)] = []
        for investigation in (try? store.investigations(runId: run.id)) ?? [] {
            for claim in (try? store.claims(investigationId: investigation.id)) ?? []
            where claim.claimType != EpistemicType.contradicted.rawValue {
                let score = CompactContextBuilder.overlap(terms, claim.statement)
                guard score > 0 else { continue }
                let anchors = ((try? store.evidence(claimIds: [claim.id])) ?? []).prefix(2).map(\.anchor)
                scored.append((
                    score,
                    "[\(claim.claimType)] \(CompactContextBuilder.truncated(claim.statement, 260))"
                        + (anchors.isEmpty ? "" : " Evidence: \(anchors.joined(separator: ", "))")))
            }
        }
        guard !scored.isEmpty else { return "No claims mention \"\(words)\"." }
        return scored.sorted { $0.0 > $1.0 }.prefix(Self.limit).map(\.1).joined(separator: "\n")
    }
}
