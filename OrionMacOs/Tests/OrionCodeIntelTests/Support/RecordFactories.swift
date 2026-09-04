import Foundation
@testable import OrionCodeIntel

/// Minimal record builders for unit tests that exercise a builder in isolation.
enum Make {
    static func file(
        id: String, path: String, module: String?, isTest: Bool = false
    ) -> FileRecord {
        FileRecord(
            id: id, repositoryId: "r", commitHash: "c", runId: "run", path: path,
            language: "python", modulePath: module, sha256: "x", byteSize: 0, lineCount: 0,
            isTest: isTest, isPackageInit: path.hasSuffix("__init__.py"), parseOk: true
        )
    }

    static func symbol(
        id: String, fileId: String, anchor: String, kind: String, name: String,
        decorators: [String] = []
    ) -> SymbolRecord {
        SymbolRecord(
            id: id, repositoryId: "r", commitHash: "c", runId: "run", fileId: fileId,
            componentId: nil, parentSymbolId: nil, name: name, qualifiedName: anchor,
            anchor: anchor, kind: kind, startLine: 1, startCol: 1, endLine: 9, endCol: 1,
            startByte: 0, endByte: 10, signature: nil, docstring: nil, decorators: decorators,
            visibility: "public", isExported: true, redirectsTo: nil, epistemicType: "FACT"
        )
    }

    static func rel(
        type: String, source: String, target: String
    ) -> RelationshipRecord {
        RelationshipRecord(
            id: "\(type)-\(source)-\(target)", repositoryId: "r", commitHash: "c", runId: "run",
            relationshipType: type, sourceSymbolId: source, targetSymbolId: target,
            externalDependencyId: nil, sourceRef: nil, targetRef: nil, provenance: "test",
            confidence: 0.9, confidenceTier: "high", resolved: true, epistemicType: "FACT",
            siteFileId: nil, siteStartLine: nil, siteStartCol: nil, siteEndLine: nil,
            siteEndCol: nil
        )
    }
}
