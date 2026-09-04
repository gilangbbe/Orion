import Foundation
import SwiftTreeSitter
import TreeSitterPython

/// Python support backed by the pinned `tree-sitter-python` grammar (pure SwiftPM, no
/// vendored C — see resolved open question #1 in the Phase 1 plan).
public struct PythonLanguageSupport: LanguageSupport {
    public init() {}

    public let language: SourceLanguage = .python
    public let symbolQueryName = "python-symbols"

    public func treeSitterLanguage() throws -> Language {
        PythonLanguageSupport.cachedLanguage
    }

    /// The grammar pointer is process-wide immutable; wrap it once.
    static let cachedLanguage = Language(tree_sitter_python())
}
