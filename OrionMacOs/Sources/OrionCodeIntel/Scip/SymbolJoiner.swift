import Foundation

/// Maps SCIP symbols to Orion symbol anchors, and finds which Orion symbol encloses a
/// source position (so a reference can be attributed to the code that made it).
public struct SymbolJoiner {
    private let relPathByModule: [String: String]
    private let symbolByAnchor: [String: SymbolRecord]
    private let symbolsByRelPath: [String: [SymbolRecord]]
    private let moduleSymbolByRelPath: [String: SymbolRecord]

    public init(files: [FileRecord], symbols: [SymbolRecord]) {
        relPathByModule = Dictionary(
            files.compactMap { f in f.modulePath.map { ($0, f.path) } },
            uniquingKeysWith: { a, _ in a }
        )
        symbolByAnchor = Dictionary(symbols.map { ($0.anchor, $0) }, uniquingKeysWith: { a, _ in a })
        symbolsByRelPath = Dictionary(grouping: symbols) { anchorFile($0.anchor) }
        moduleSymbolByRelPath = Dictionary(
            symbols.filter { $0.kind == "module" || $0.kind == "package" }
                .map { ($0.anchor, $0) },
            uniquingKeysWith: { a, _ in a }
        )
    }

    /// The Orion anchor for a SCIP symbol, or nil if it is local / external / not indexed.
    public func anchor(for scip: ScipSymbol) -> String? {
        guard !scip.isLocal, let module = scip.moduleDotted,
              let relPath = relPathByModule[module]
        else { return nil }
        if scip.isModuleSymbol { return relPath }
        let candidate = "\(relPath)::\(scip.inFileDotted)"
        return symbolByAnchor[candidate] != nil ? candidate : nil
    }

    public func symbol(forAnchor anchor: String) -> SymbolRecord? {
        symbolByAnchor[anchor]
    }

    /// Innermost Orion symbol in `relPath` whose line range covers `line` (1-based),
    /// falling back to the file's module symbol.
    public func enclosingSymbol(relPath: String, line: Int) -> SymbolRecord? {
        let candidates = (symbolsByRelPath[relPath] ?? []).filter {
            $0.startLine <= line && line <= $0.endLine
                && $0.kind != "module" && $0.kind != "package"
                && $0.kind != "import_alias" && $0.kind != "reexport"
        }
        if let innermost = candidates.min(by: { spanBytes($0) < spanBytes($1) }) {
            return innermost
        }
        return moduleSymbolByRelPath[relPath]
    }

    private func spanBytes(_ s: SymbolRecord) -> Int { s.endByte - s.startByte }
}

private func anchorFile(_ anchor: String) -> String {
    if let r = anchor.range(of: "::") { return String(anchor[anchor.startIndex..<r.lowerBound]) }
    return anchor
}
