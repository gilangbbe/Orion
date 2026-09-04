import Foundation

/// Assembles a run's rows into the shapes the JSON/JSONL export emits. Kept separate from
/// the file writer so the shapes are unit-testable.
public struct CodeGraphModel {
    let run: AnalysisRunRecord
    let repo: RepositoryRecord?
    let files: [FileRecord]
    let symbols: [SymbolRecord]
    let relationships: [RelationshipRecord]
    let externalDependencies: [ExternalDependencyRecord]
    let diagnostics: [DiagnosticRecord]

    // lookups
    private let fileById: [String: FileRecord]
    private let pathByFileId: [String: String]
    private let symbolById: [String: SymbolRecord]
    private let anchorBySymbolId: [String: String]
    private let extDepById: [String: ExternalDependencyRecord]
    private let moduleSymbolByPath: [String: SymbolRecord]

    public init(
        run: AnalysisRunRecord, repo: RepositoryRecord?, files: [FileRecord],
        symbols: [SymbolRecord], relationships: [RelationshipRecord],
        externalDependencies: [ExternalDependencyRecord], diagnostics: [DiagnosticRecord]
    ) {
        self.run = run
        self.repo = repo
        self.files = files
        self.symbols = symbols
        self.relationships = relationships
        self.externalDependencies = externalDependencies
        self.diagnostics = diagnostics

        fileById = Dictionary(uniqueKeysWithValues: files.map { ($0.id, $0) })
        pathByFileId = Dictionary(uniqueKeysWithValues: files.map { ($0.id, $0.path) })
        symbolById = Dictionary(uniqueKeysWithValues: symbols.map { ($0.id, $0) })
        anchorBySymbolId = Dictionary(uniqueKeysWithValues: symbols.map { ($0.id, $0.anchor) })
        extDepById = Dictionary(uniqueKeysWithValues: externalDependencies.map { ($0.id, $0) })
        moduleSymbolByPath = Dictionary(
            symbols.filter { $0.kind == "module" || $0.kind == "package" }
                .map { ($0.qualifiedName, $0) },
            uniquingKeysWith: { a, _ in a }
        )
    }

    // MARK: repository.json

    public struct RepositoryExport: Encodable {
        public var id: String
        public var sourceURL: String?
        public var localPath: String
        public var commitHash: String
        public var languages: [String]
        public var analyzedAt: String?
        public var orionVersion: String
        public var resolver: String
        public var grammarVersions: [String: String]
        public var counts: Counts
        public var resolution: Resolution

        public struct Counts: Encodable {
            public var files, symbols, relationships, externalDependencies, diagnostics: Int
        }
        public struct Resolution: Encodable {
            public var totalRelationships, resolvedRelationships, calls: Int
            public var resolvedRelationshipRate: Double
        }
    }

    public func repositoryExport() -> RepositoryExport {
        let resolved = relationships.filter { $0.resolved }.count
        let calls = relationships.filter { $0.relationshipType == "calls" }.count
        return RepositoryExport(
            id: run.repositoryId,
            sourceURL: repo?.sourceURL,
            localPath: repo?.localPath ?? "",
            commitHash: run.commitHash,
            languages: repo?.languages ?? [],
            analyzedAt: run.finishedAt,
            orionVersion: run.orionVersion,
            resolver: run.resolver,
            grammarVersions: run.grammarVersions,
            counts: .init(
                files: files.count, symbols: symbols.count, relationships: relationships.count,
                externalDependencies: externalDependencies.count, diagnostics: diagnostics.count
            ),
            resolution: .init(
                totalRelationships: relationships.count, resolvedRelationships: resolved,
                calls: calls,
                resolvedRelationshipRate: relationships.isEmpty
                    ? 0 : Double(resolved) / Double(relationships.count)
            )
        )
    }

    // MARK: files.jsonl

    public struct FileExport: Encodable {
        public var id, path: String
        public var modulePath, language: String?
        public var isTest, isPackageInit, parseOk: Bool
        public var lineCount: Int
        public var sha256: String
        public var symbolIds: [String]
    }

    public func fileExports() -> [FileExport] {
        let idsByFile = Dictionary(grouping: symbols, by: { $0.fileId })
            .mapValues { $0.sorted { $0.startByte < $1.startByte }.map(\.id) }
        return files.map { f in
            FileExport(
                id: f.id, path: f.path, modulePath: f.modulePath, language: f.language,
                isTest: f.isTest, isPackageInit: f.isPackageInit, parseOk: f.parseOk,
                lineCount: f.lineCount, sha256: f.sha256, symbolIds: idsByFile[f.id] ?? []
            )
        }
    }

    // MARK: symbols.jsonl

    public struct RangeExport: Encodable {
        public var startLine, startCol, endLine, endCol: Int
    }
    public struct SymbolExport: Encodable {
        public var id, anchor, qualifiedName, name, kind, file: String
        public var modulePath, parentAnchor, redirectsTo: String?
        public var range: RangeExport
        public var signature, docstring: String?
        public var decorators: [String]
        public var visibility: String
        public var isExported: Bool
        public var epistemicType: String
    }

    public func symbolExports() -> [SymbolExport] {
        let parentAnchorById = Dictionary(uniqueKeysWithValues: symbols.map {
            ($0.id, $0.parentSymbolId.flatMap { anchorBySymbolId[$0] })
        })
        return symbols.map { s in
            SymbolExport(
                id: s.id, anchor: s.anchor, qualifiedName: s.qualifiedName, name: s.name,
                kind: s.kind, file: pathByFileId[s.fileId] ?? "",
                modulePath: fileById[s.fileId]?.modulePath,
                parentAnchor: parentAnchorById[s.id] ?? nil,
                redirectsTo: s.redirectsTo,
                range: .init(
                    startLine: s.startLine, startCol: s.startCol,
                    endLine: s.endLine, endCol: s.endCol
                ),
                signature: s.signature, docstring: s.docstring, decorators: s.decorators,
                visibility: s.visibility, isExported: s.isExported, epistemicType: s.epistemicType
            )
        }
    }

    // MARK: relationships.jsonl

    public struct EndpointExport: Encodable {
        public var anchor, kind, ref: String?
        public var external: Bool?
    }
    public struct SiteExport: Encodable {
        public var file: String?
        public var startLine, endLine: Int?
    }
    public struct RelationshipExport: Encodable {
        public var id, type, provenance, confidenceTier, epistemicType: String
        public var confidence: Double
        public var resolved: Bool
        public var source, target: EndpointExport
        public var site: SiteExport?
    }

    public func relationshipExports() -> [RelationshipExport] {
        relationships.map { r in
            let source: EndpointExport
            if let sid = r.sourceSymbolId, let s = symbolById[sid] {
                source = EndpointExport(anchor: s.anchor, kind: s.kind, ref: nil, external: nil)
            } else {
                source = EndpointExport(anchor: nil, kind: nil, ref: r.sourceRef, external: nil)
            }

            let target: EndpointExport
            if let tid = r.targetSymbolId, let t = symbolById[tid] {
                target = EndpointExport(anchor: t.anchor, kind: t.kind, ref: nil, external: nil)
            } else if let eid = r.externalDependencyId {
                target = EndpointExport(
                    anchor: nil, kind: nil,
                    ref: r.targetRef ?? extDepById[eid]?.name, external: true
                )
            } else if let ref = r.targetRef {
                target = EndpointExport(anchor: nil, kind: nil, ref: ref, external: true)
            } else {
                target = EndpointExport(anchor: nil, kind: nil, ref: nil, external: nil)
            }

            var site: SiteExport?
            if let sf = r.siteFileId {
                site = SiteExport(
                    file: pathByFileId[sf], startLine: r.siteStartLine, endLine: r.siteEndLine
                )
            }

            return RelationshipExport(
                id: r.id, type: r.relationshipType, provenance: r.provenance,
                confidenceTier: r.confidenceTier, epistemicType: r.epistemicType,
                confidence: r.confidence, resolved: r.resolved,
                source: source, target: target, site: site
            )
        }
    }

    // MARK: external_dependencies.jsonl

    public struct ExternalDependencyExport: Encodable {
        public var id, name, source: String
        public var distribution, versionSpec: String?
        public var isStdlib: Bool
        public var importCount: Int
    }

    public func externalDependencyExports() -> [ExternalDependencyExport] {
        externalDependencies.map {
            ExternalDependencyExport(
                id: $0.id, name: $0.name, source: $0.source, distribution: $0.distribution,
                versionSpec: $0.versionSpec, isStdlib: $0.isStdlib, importCount: $0.importCount
            )
        }
    }

    // MARK: diagnostics.jsonl

    public struct DiagnosticExport: Encodable {
        public var stage, severity, code, message: String
        public var file: String?
        public var startLine, endLine: Int?
    }

    public func diagnosticExports() -> [DiagnosticExport] {
        diagnostics.map {
            DiagnosticExport(
                stage: $0.stage, severity: $0.severity, code: $0.code, message: $0.message,
                file: $0.fileId.flatMap { pathByFileId[$0] },
                startLine: $0.startLine, endLine: $0.endLine
            )
        }
    }

    // MARK: code_graph.json

    public struct CodeGraphExport: Encodable {
        public var repository: RepositoryExport
        public var stats: Stats
        public var modules: [ModuleNode]
        public var classes: [ClassNode]
        public var entrypoints: [String]
        public var testMap: [TestMapEntry]

        public struct Stats: Encodable {
            public var symbolsByKind: [String: Int]
            public var relationshipsByType: [String: Int]
        }
        public struct ModuleNode: Encodable {
            public var modulePath, file: String
            public var symbols, imports, importedBy, externalImports: [String]
        }
        public struct ClassNode: Encodable {
            public var anchor: String
            public var bases, methods: [String]
        }
        public struct TestMapEntry: Encodable {
            public var test: String
            public var targets: [String]
        }
    }

    public func codeGraphExport() -> CodeGraphExport {
        let symbolsByKind = Dictionary(grouping: symbols, by: \.kind).mapValues(\.count)
        let relsByType = Dictionary(grouping: relationships, by: \.relationshipType).mapValues(\.count)

        // module import matrix
        var importsOf: [String: Set<String>] = [:]      // modulePath -> imported modulePaths
        var importedBy: [String: Set<String>] = [:]
        var externalOf: [String: Set<String>] = [:]
        for r in relationships {
            guard let sid = r.sourceSymbolId, let s = symbolById[sid],
                  s.kind == "module" || s.kind == "package" else { continue }
            if r.relationshipType == "imports", let tid = r.targetSymbolId,
               let t = symbolById[tid] {
                importsOf[s.qualifiedName, default: []].insert(t.qualifiedName)
                importedBy[t.qualifiedName, default: []].insert(s.qualifiedName)
            } else if r.relationshipType == "depends_on",
                      let eid = r.externalDependencyId, let dep = extDepById[eid] {
                externalOf[s.qualifiedName, default: []].insert(dep.name)
            }
        }

        let topLevelByModule = Dictionary(grouping: symbols.filter {
            $0.parentSymbolId != nil
                && ["class", "function", "constant", "variable", "reexport"].contains($0.kind)
        }) { sym -> String in
            fileById[sym.fileId]?.modulePath ?? ""
        }

        let modules: [CodeGraphExport.ModuleNode] = files
            .filter { $0.language == "python" && $0.modulePath != nil }
            .compactMap { f in
                guard let mp = f.modulePath, moduleSymbolByPath[mp] != nil else { return nil }
                let members = (topLevelByModule[mp] ?? [])
                    .filter { anchorFile($0.anchor) == f.path }
                    .sorted { $0.startByte < $1.startByte }.map(\.anchor)
                return .init(
                    modulePath: mp, file: f.path, symbols: members,
                    imports: (importsOf[mp] ?? []).sorted(),
                    importedBy: (importedBy[mp] ?? []).sorted(),
                    externalImports: (externalOf[mp] ?? []).sorted()
                )
            }

        // classes with bases + methods
        let basesOf = Dictionary(grouping: relationships.filter {
            ($0.relationshipType == "extends" || $0.relationshipType == "implements")
        }) { $0.sourceSymbolId ?? "" }
        let methodsByParent = Dictionary(grouping: symbols.filter {
            ($0.kind == "method" || $0.kind == "property") && $0.parentSymbolId != nil
        }) { $0.parentSymbolId! }

        let classes: [CodeGraphExport.ClassNode] = symbols
            .filter { $0.kind == "class" }
            .map { c in
                let bases = (basesOf[c.id] ?? []).compactMap { rel -> String? in
                    if let tid = rel.targetSymbolId { return anchorBySymbolId[tid] }
                    return rel.targetRef
                }.sorted()
                let methods = (methodsByParent[c.id] ?? [])
                    .sorted { $0.startByte < $1.startByte }.map(\.anchor)
                return .init(anchor: c.anchor, bases: bases, methods: methods)
            }
            .sorted { $0.anchor < $1.anchor }

        // entrypoints: most-referenced non-test module/class/function symbols
        var inbound: [String: Int] = [:]
        for r in relationships {
            guard ["imports", "calls", "references", "extends", "implements"].contains(r.relationshipType),
                  let tid = r.targetSymbolId else { continue }
            inbound[tid, default: 0] += 1
        }
        let entrypoints = inbound
            .compactMap { id, n -> (String, Int)? in
                guard let s = symbolById[id], !(fileById[s.fileId]?.isTest ?? true),
                      ["module", "package", "class", "function"].contains(s.kind) else { return nil }
                return (s.anchor, n)
            }
            .sorted { $0.1 == $1.1 ? $0.0 < $1.0 : $0.1 > $1.1 }
            .prefix(20)
            .map(\.0)

        // test map
        let testMap: [CodeGraphExport.TestMapEntry] = Dictionary(grouping: relationships.filter {
            $0.relationshipType == "tested_by"
        }) { $0.sourceSymbolId ?? "" }
            .compactMap { srcId, rels -> CodeGraphExport.TestMapEntry? in
                guard let src = symbolById[srcId] else { return nil }
                let targets = rels.compactMap { $0.targetSymbolId.flatMap { anchorBySymbolId[$0] } }
                    .sorted()
                return .init(test: src.anchor, targets: targets)
            }
            .sorted { $0.test < $1.test }

        return CodeGraphExport(
            repository: repositoryExport(),
            stats: .init(symbolsByKind: symbolsByKind, relationshipsByType: relsByType),
            modules: modules, classes: classes, entrypoints: Array(entrypoints), testMap: testMap
        )
    }
}

private func anchorFile(_ anchor: String) -> String {
    if let r = anchor.range(of: "::") { return String(anchor[anchor.startIndex..<r.lowerBound]) }
    return anchor
}
