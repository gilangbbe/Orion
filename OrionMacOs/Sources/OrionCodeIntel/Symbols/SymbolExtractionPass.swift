import Foundation

/// Parses each Python file and runs `PythonSymbolExtractor`. Sequential (one reusable
/// parser); the extractor walk dominates and Phase 1 corpora are small. Files that fail to
/// parse still contribute whatever partial tree tree-sitter recovered.
public struct SymbolExtractionPass {
    public let support: any LanguageSupport

    public init(support: any LanguageSupport = PythonLanguageSupport()) {
        self.support = support
    }

    public struct Input: Sendable {
        public let fileId: String
        public let relPath: String
        public let absolutePath: String
        public let modulePath: String?
        public let isPackageInit: Bool

        public init(
            fileId: String, relPath: String, absolutePath: String,
            modulePath: String?, isPackageInit: Bool
        ) {
            self.fileId = fileId
            self.relPath = relPath
            self.absolutePath = absolutePath
            self.modulePath = modulePath
            self.isPackageInit = isPackageInit
        }
    }

    public func run(_ inputs: [Input]) throws -> [FileSymbols] {
        let parser = try TreeSitterParser(support)
        let extractor = PythonSymbolExtractor()
        return inputs.map { input in
            guard
                let data = try? Data(contentsOf: URL(fileURLWithPath: input.absolutePath)),
                let parsed = parser.parse(
                    fileId: input.fileId, relPath: input.relPath, source: data
                )
            else {
                return FileSymbols(
                    fileId: input.fileId, relPath: input.relPath,
                    modulePath: input.modulePath, symbols: [], diagnostics: []
                )
            }
            return extractor.extract(
                parsed, modulePath: input.modulePath, isPackageInit: input.isPackageInit
            )
        }
    }
}
