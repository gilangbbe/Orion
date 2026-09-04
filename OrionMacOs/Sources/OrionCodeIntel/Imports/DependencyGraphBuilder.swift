import Foundation

/// Builds `imports` (module → in-repo module) and `depends_on` (module → external
/// dependency) edges from the `import_alias` / `reexport` symbols M3 produced, and mints
/// `external_dependencies` rows for imports not already declared in project metadata.
///
/// These edges are syntactic facts (an import statement is right there in the source), so
/// they are `confidence_tier = high`. Symbol-level precision (`from x import Y` → the class
/// `Y`) is SCIP's job in M5.
public struct DependencyGraphBuilder {
    public let repositoryId: String
    public let commitHash: String
    public let runId: String

    public init(repositoryId: String, commitHash: String, runId: String) {
        self.repositoryId = repositoryId
        self.commitHash = commitHash
        self.runId = runId
    }

    public struct Output {
        public var relationships: [RelationshipRecord] = []
        public var newExternalDependencies: [ExternalDependencyRecord] = []
        public var importCounts: [(id: String, count: Int)] = []
        public var diagnostics: [(fileId: String, code: String, message: String)] = []
    }

    public func build(
        files: [FileRecord], symbols: [SymbolRecord],
        existingExternalDependencies: [ExternalDependencyRecord]
    ) -> Output {
        var out = Output()

        let fileById = Dictionary(uniqueKeysWithValues: files.map { ($0.id, $0) })
        let moduleIdByPath = Dictionary(
            symbols.filter { $0.kind == "module" || $0.kind == "package" }
                .map { ($0.qualifiedName, $0.id) },
            uniquingKeysWith: { a, _ in a }
        )
        let resolver = ModuleResolver(
            inRepoModules: Set(files.compactMap { $0.language == "python" ? $0.modulePath : nil })
        )

        var extDepIdByName = Dictionary(
            uniqueKeysWithValues: existingExternalDependencies.map { ($0.name, $0.id) }
        )
        var mintedExtDeps: [String: ExternalDependencyRecord] = [:]
        var seenEdgeIDs = Set<String>()
        var dependsOnCountByExtId: [String: Int] = [:]

        for imp in symbols where imp.kind == "import_alias" || imp.kind == "reexport" {
            guard let redirect = imp.redirectsTo,
                  let file = fileById[imp.fileId], let importerModule = file.modulePath,
                  let sourceId = moduleIdByPath[importerModule]
            else { continue }

            let (spec, importedName) = splitRedirect(redirect)
            guard !spec.isEmpty || importedName != nil else { continue }

            let target = resolver.resolve(
                spec: spec, importedName: importedName,
                importerModulePath: importerModule, importerIsPackage: file.isPackageInit
            )

            switch target {
            case .inRepoModule(let modulePath):
                guard let targetId = moduleIdByPath[modulePath], targetId != sourceId else { continue }
                let id = DeterministicID.relationship(
                    repositoryId: repositoryId, commitHash: commitHash,
                    type: "imports", source: sourceId, target: targetId, site: ""
                )
                guard seenEdgeIDs.insert(id).inserted else { continue }
                out.relationships.append(edge(
                    id: id, type: "imports", sourceSymbolId: sourceId, targetSymbolId: targetId,
                    externalDependencyId: nil, targetRef: modulePath, imp: imp
                ))

            case .external(let topLevel, let full):
                let extId = ensureExternalDependency(
                    name: topLevel, into: &mintedExtDeps, extDepIdByName: &extDepIdByName
                )
                let id = DeterministicID.relationship(
                    repositoryId: repositoryId, commitHash: commitHash,
                    type: "depends_on", source: sourceId, target: extId, site: ""
                )
                dependsOnCountByExtId[extId, default: 0] += 1
                guard seenEdgeIDs.insert(id).inserted else { continue }
                out.relationships.append(edge(
                    id: id, type: "depends_on", sourceSymbolId: sourceId, targetSymbolId: nil,
                    externalDependencyId: extId, targetRef: full, imp: imp
                ))

            case .unresolvable(let s):
                out.diagnostics.append((
                    imp.fileId, "IMPORT_UNRESOLVED",
                    "could not resolve import `\(s)` in \(file.path)"
                ))
            }
        }

        out.newExternalDependencies = mintedExtDeps.values.sorted { $0.name < $1.name }

        // import_count for every dependency that got at least one depends_on edge
        var allIds = Set(dependsOnCountByExtId.keys)
        allIds.formUnion(existingExternalDependencies.map { $0.id })
        out.importCounts = allIds
            .map { ($0, dependsOnCountByExtId[$0] ?? 0) }
            .sorted { $0.0 < $1.0 }

        return out
    }

    // MARK: helpers

    private func splitRedirect(_ redirect: String) -> (spec: String, importedName: String?) {
        if let range = redirect.range(of: "::") {
            return (String(redirect[redirect.startIndex..<range.lowerBound]),
                    String(redirect[range.upperBound...]))
        }
        return (redirect, nil)
    }

    private func ensureExternalDependency(
        name: String, into minted: inout [String: ExternalDependencyRecord],
        extDepIdByName: inout [String: String]
    ) -> String {
        if let id = extDepIdByName[name] { return id }
        let id = DeterministicID.externalDependency(
            repositoryId: repositoryId, commitHash: commitHash, name: name
        )
        let isStdlib = StdlibModules.contains(name)
        minted[name] = ExternalDependencyRecord(
            id: id, repositoryId: repositoryId, commitHash: commitHash, runId: runId,
            name: name, distribution: nil,
            source: (isStdlib ? ExternalDependencySource.stdlib : .inferred).rawValue,
            versionSpec: nil, isStdlib: isStdlib, importCount: 0
        )
        extDepIdByName[name] = id
        return id
    }

    private func edge(
        id: String, type: String, sourceSymbolId: String?, targetSymbolId: String?,
        externalDependencyId: String?, targetRef: String, imp: SymbolRecord
    ) -> RelationshipRecord {
        RelationshipRecord(
            id: id, repositoryId: repositoryId, commitHash: commitHash, runId: runId,
            relationshipType: type, sourceSymbolId: sourceSymbolId,
            targetSymbolId: targetSymbolId, externalDependencyId: externalDependencyId,
            sourceRef: nil, targetRef: targetRef, provenance: "ast:import",
            confidence: ConfidenceTier.high.score, confidenceTier: ConfidenceTier.high.rawValue,
            resolved: true, epistemicType: EpistemicType.fact.rawValue,
            siteFileId: imp.fileId, siteStartLine: imp.startLine, siteStartCol: imp.startCol,
            siteEndLine: imp.endLine, siteEndCol: imp.endCol
        )
    }
}
