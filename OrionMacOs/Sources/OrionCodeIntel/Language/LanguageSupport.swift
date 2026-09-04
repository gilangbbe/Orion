import Foundation
import SwiftTreeSitter

/// Source languages the analyzer can ingest. Phase 1 ships `python` only; the enum exists so
/// the pipeline, CLI flags, and `files.language` column are already language-agnostic.
public enum SourceLanguage: String, CaseIterable, Sendable {
    case python

    /// File extensions (lowercased, no dot) that map to this language.
    public var fileExtensions: Set<String> {
        switch self {
        case .python: return ["py", "pyi"]
        }
    }

    public init?(fileExtension ext: String) {
        let needle = ext.lowercased()
        guard let match = SourceLanguage.allCases.first(where: { $0.fileExtensions.contains(needle) })
        else { return nil }
        self = match
    }
}

/// Per-language hooks the pipeline needs. Kept deliberately small for Phase 1 — just the
/// tree-sitter grammar plus the identifiers used to locate the bundled query files.
public protocol LanguageSupport: Sendable {
    var language: SourceLanguage { get }
    /// The tree-sitter grammar for this language.
    func treeSitterLanguage() throws -> Language
    /// Base name (without extension) of the `.scm` query bundled under `Symbols/Queries/`.
    var symbolQueryName: String { get }
}

public enum LanguageSupportError: Error, CustomStringConvertible {
    case grammarUnavailable(SourceLanguage)
    case queryResourceMissing(String)

    public var description: String {
        switch self {
        case .grammarUnavailable(let lang):
            return "tree-sitter grammar unavailable for \(lang.rawValue)"
        case .queryResourceMissing(let name):
            return "bundled query resource missing: \(name).scm"
        }
    }
}

/// Resolves a `LanguageSupport` for a given `SourceLanguage`.
public struct LanguageRegistry: Sendable {
    private let providers: [SourceLanguage: any LanguageSupport]

    public init(providers: [any LanguageSupport] = [PythonLanguageSupport()]) {
        self.providers = Dictionary(uniqueKeysWithValues: providers.map { ($0.language, $0) })
    }

    public func support(for language: SourceLanguage) throws -> any LanguageSupport {
        guard let provider = providers[language] else {
            throw LanguageSupportError.grammarUnavailable(language)
        }
        return provider
    }
}
