import Foundation

/// A symbol lifted from one file's syntax tree, before it is assigned a database id.
public struct ExtractedSymbol: Sendable, Equatable {
    public var kind: SymbolKind
    public var name: String
    public var qualifiedName: String
    /// Benchmark form: `<repo-relative path>::<dotted in-file nesting>` (module symbol = the
    /// bare path).
    public var anchor: String
    public var parentAnchor: String?
    public var startByte: Int
    public var endByte: Int
    public var startLine: Int
    public var startCol: Int
    public var endLine: Int
    public var endCol: Int
    public var signature: String?
    public var docstring: String?
    public var decorators: [String]
    public var visibility: String
    public var isExported: Bool
    /// For `import_alias` / `reexport`: a textual reference to the target
    /// (`<module-spec>::<name>`), rewritten to a real anchor by M5 where resolvable.
    public var redirectsTo: String?
}

public struct ExtractionDiagnostic: Sendable, Equatable {
    public var code: String
    public var message: String
    public var line: Int?
    public var col: Int?
}

public struct FileSymbols: Sendable {
    public var fileId: String
    public var relPath: String
    public var modulePath: String?
    public var symbols: [ExtractedSymbol]
    public var diagnostics: [ExtractionDiagnostic]
}

enum SymbolVisibility {
    /// `_x` → private, `__x` (no dunder suffix) → private (name-mangled), `__x__` → dunder.
    static func classify(_ name: String) -> String {
        if name.hasPrefix("__") && name.hasSuffix("__") && name.count > 4 { return "dunder" }
        if name.hasPrefix("_") { return "private" }
        return "public"
    }
}
