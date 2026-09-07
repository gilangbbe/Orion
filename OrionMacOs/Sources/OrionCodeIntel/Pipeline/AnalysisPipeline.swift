import Foundation

/// Phase 1 orchestrator. M1 ingestion + M2 parsing/diagnostics are implemented; symbols,
/// resolution, and export are wired in M3–M7.
public struct AnalysisPipeline {
    public let database: OrionDatabase
    private var store: Store { Store(database) }

    public init(database: OrionDatabase) {
        self.database = database
    }

    public func run(
        _ input: AnalysisInput, progress: (any AnalysisProgressReporting)? = nil
    ) throws -> AnalysisResult {
        let timings = StageTimings()
        let fm = FileManager.default

        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: input.repoPath.path, isDirectory: &isDir), isDir.boolValue else {
            throw PipelineError.notADirectory(input.repoPath.path)
        }

        progress?.pipelineDidStart(stage: .ingestion)

        // --- resolve commit (optionally checking out, always restoring) --------------
        let git = GitRunner(repoPath: input.repoPath)
        let isGit = git.isRepository()
        var restore: (() -> Void)?
        var commitHash = "unversioned"

        if isGit {
            let originalHead = try git.headCommit()
            let originalBranch = git.currentBranch()
            if let wanted = input.explicitCommit, wanted != originalHead {
                try timings.measure("checkout") { try git.checkout(wanted) }
                restore = {
                    try? git.checkout(originalBranch.isEmpty ? originalHead : originalBranch)
                }
            }
            commitHash = try git.headCommit()
        }
        defer { restore?() }

        // --- discover + measure files ------------------------------------------------
        let tracked = isGit ? try git.trackedFiles() : nil
        let scanner = RepositoryScanner(root: input.repoPath, maxFileBytes: input.maxFileBytes)
        let scanned = try timings.measure("ingest.scan") { try scanner.scan(trackedRelPaths: tracked) }

        let languages = Set(scanned.compactMap { $0.language?.rawValue }).sorted()
        let pythonFiles = scanned.filter { $0.language == .python }
        let jobs = max(1, input.jobs ?? ProcessInfo.processInfo.activeProcessorCount)

        // --- persist ---------------------------------------------------------------
        let now = Timestamp.now()
        let repo = try store.upsertRepository(
            localPath: input.repoPath.path, commitHash: commitHash, sourceURL: input.sourceURL,
            languages: languages, status: .running, now: now
        )
        if input.clean {
            try store.deleteRuns(repositoryId: repo.id, commitHash: commitHash)
        }

        let run = try store.startRun(
            repositoryId: repo.id, commitHash: commitHash, startedAt: now,
            orionVersion: OrionCodeIntel.version, resolver: "none",
            grammarVersions: ["python": PythonLanguageSupport.grammarVersion]
        )

        do {
            var diagnostics: [DiagnosticRecord] = []
            func diagnose(
                fileId: String?, stage: String, severity: String, code: String,
                message: String, scope: String,
                start: LineIndex.Position? = nil, end: LineIndex.Position? = nil
            ) {
                diagnostics.append(DiagnosticRecord(
                    id: DeterministicID.diagnostic(
                        repositoryId: repo.id, commitHash: commitHash, stage: stage,
                        code: code, scope: scope, ordinal: diagnostics.count
                    ),
                    repositoryId: repo.id, commitHash: commitHash, runId: run.id, fileId: fileId,
                    stage: stage, severity: severity, code: code, message: message,
                    startLine: start?.line, startCol: start?.column,
                    endLine: end?.line, endCol: end?.column
                ))
            }

            // files
            let fileRecords: [FileRecord] = scanned.map { sf in
                FileRecord(
                    id: DeterministicID.file(
                        repositoryId: repo.id, commitHash: commitHash, path: sf.relPath
                    ),
                    repositoryId: repo.id, commitHash: commitHash, runId: run.id,
                    path: sf.relPath, language: sf.language?.rawValue, modulePath: sf.modulePath,
                    sha256: sf.sha256, byteSize: sf.byteSize, lineCount: sf.lineCount,
                    isTest: sf.isTest, isPackageInit: sf.isPackageInit, parseOk: true
                )
            }
            try timings.measure("persist.files") { try store.insertFiles(fileRecords) }
            let fileIDByPath = Dictionary(uniqueKeysWithValues: fileRecords.map { ($0.path, $0.id) })

            for sf in scanned {
                if sf.skippedReason == "oversize" {
                    diagnose(
                        fileId: fileIDByPath[sf.relPath], stage: "ingest", severity: "info",
                        code: "FILE_SKIPPED_OVERSIZE",
                        message: "\(sf.relPath) is \(sf.byteSize) bytes (> \(input.maxFileBytes)); recorded but not parsed",
                        scope: sf.relPath
                    )
                }
                if sf.language == .python, sf.modulePath == nil {
                    diagnose(
                        fileId: fileIDByPath[sf.relPath], stage: "ingest", severity: "warning",
                        code: "MODULE_PATH_UNRESOLVED",
                        message: "could not compute a dotted module path for \(sf.relPath)",
                        scope: sf.relPath
                    )
                }
            }

            // parse (M2)
            let specs: [ParseFileSpec] = scanned.compactMap { sf in
                guard sf.language == .python, sf.skippedReason == nil,
                      let fid = fileIDByPath[sf.relPath] else { return nil }
                return ParseFileSpec(
                    fileId: fid, relPath: sf.relPath,
                    absolutePath: input.repoPath.appendingPathComponent(sf.relPath).path
                )
            }
            progress?.pipelineDidStart(stage: .ast)
            let outcomes = timings.measure("parse") {
                PythonParsePass().run(specs, jobs: jobs)
            }

            var failedFileIDs: [String] = []
            for outcome in outcomes where !outcome.parseOk {
                failedFileIDs.append(outcome.fileId)
                if !outcome.parsed {
                    diagnose(
                        fileId: outcome.fileId, stage: "parse", severity: "error",
                        code: "PARSE_FAILED",
                        message: "tree-sitter produced no tree for \(outcome.relPath)",
                        scope: outcome.relPath
                    )
                }
                for span in outcome.errors {
                    diagnose(
                        fileId: outcome.fileId, stage: "parse", severity: "warning",
                        code: span.kind == .missing ? "MISSING_NODE" : "PARSE_ERROR",
                        message: "\(span.kind.rawValue) at \(span.startLine):\(span.startCol)"
                            + (span.snippet.map { " near `\($0)`" } ?? ""),
                        scope: "\(outcome.relPath)#\(span.startLine):\(span.startCol)",
                        start: LineIndex.Position(line: span.startLine, column: span.startCol),
                        end: LineIndex.Position(line: span.endLine, column: span.endCol)
                    )
                }
            }
            if !failedFileIDs.isEmpty {
                try store.updateParseOk(fileIds: failedFileIDs, parseOk: false)
            }

            // symbols (M3)
            let symbolInputs: [SymbolExtractionPass.Input] = scanned.compactMap { sf in
                guard sf.language == .python, sf.skippedReason == nil,
                      let fid = fileIDByPath[sf.relPath] else { return nil }
                return SymbolExtractionPass.Input(
                    fileId: fid, relPath: sf.relPath,
                    absolutePath: input.repoPath.appendingPathComponent(sf.relPath).path,
                    modulePath: sf.modulePath, isPackageInit: sf.isPackageInit
                )
            }
            progress?.pipelineDidStart(stage: .symbols)
            let fileSymbols = try timings.measure("symbols") {
                try SymbolExtractionPass().run(symbolInputs)
            }
            var symbolRecords: [SymbolRecord] = []
            for fs in fileSymbols {
                for sym in fs.symbols {
                    symbolRecords.append(SymbolRecord(
                        id: DeterministicID.symbol(
                            repositoryId: repo.id, commitHash: commitHash, anchor: sym.anchor
                        ),
                        repositoryId: repo.id, commitHash: commitHash, runId: run.id,
                        fileId: fs.fileId, componentId: nil,
                        parentSymbolId: sym.parentAnchor.map {
                            DeterministicID.symbol(
                                repositoryId: repo.id, commitHash: commitHash, anchor: $0
                            )
                        },
                        name: sym.name, qualifiedName: sym.qualifiedName, anchor: sym.anchor,
                        kind: sym.kind.rawValue,
                        startLine: sym.startLine, startCol: sym.startCol,
                        endLine: sym.endLine, endCol: sym.endCol,
                        startByte: sym.startByte, endByte: sym.endByte,
                        signature: sym.signature, docstring: sym.docstring,
                        decorators: sym.decorators, visibility: sym.visibility,
                        isExported: sym.isExported, redirectsTo: sym.redirectsTo,
                        epistemicType: EpistemicType.fact.rawValue
                    ))
                }
                for d in fs.diagnostics {
                    diagnose(
                        fileId: fs.fileId, stage: "symbols", severity: "info", code: d.code,
                        message: d.message, scope: "\(fs.relPath)#\(d.code):\(d.line ?? 0):\(d.col ?? 0)",
                        start: d.line.map { LineIndex.Position(line: $0, column: d.col ?? 1) }
                    )
                }
            }
            try timings.measure("persist.symbols") { try store.insertSymbols(symbolRecords) }

            // declared external dependencies (pyproject / requirements)
            var externalDeps = try timings.measure("ingest.manifests") {
                try collectExternalDependencies(
                    root: input.repoPath, repo: repo.id, commit: commitHash, run: run.id
                )
            }
            try store.insertExternalDependencies(externalDeps)

            // imports + dependency graph (M4)
            progress?.pipelineDidStart(stage: .imports)
            let dep = timings.measure("imports") {
                DependencyGraphBuilder(
                    repositoryId: repo.id, commitHash: commitHash, runId: run.id
                ).build(
                    files: fileRecords, symbols: symbolRecords,
                    existingExternalDependencies: externalDeps
                )
            }
            try store.insertExternalDependencies(dep.newExternalDependencies)
            externalDeps.append(contentsOf: dep.newExternalDependencies)
            try timings.measure("persist.relationships") {
                try store.insertRelationships(dep.relationships)
            }
            try store.updateImportCounts(dep.importCounts)
            for d in dep.diagnostics {
                diagnose(
                    fileId: d.fileId, stage: "imports", severity: "info", code: d.code,
                    message: d.message, scope: "\(d.fileId)#\(d.code):\(diagnostics.count)"
                )
            }

            // SCIP resolution: calls / extends / implements (M5)
            progress?.pipelineDidStart(stage: .scip)
            var resolverLabel = "none"
            var scipRelationships: [RelationshipRecord] = []
            if input.resolve {
                let scipDir = input.outputDirectory.appendingPathComponent("scip")
                try? fm.createDirectory(at: scipDir, withIntermediateDirectories: true)
                let indexer = ScipIndexer(
                    repoRoot: input.repoPath, workDir: scipDir,
                    projectName: pyProjectName(root: input.repoPath)
                        ?? input.repoPath.lastPathComponent,
                    projectVersion: commitHash
                )
                switch timings.measure("scip.index", { indexer.run() }) {
                case .success(let indexPath, let resolver):
                    let data = try Data(contentsOf: indexPath)
                    let index = try timings.measure("scip.decode") {
                        try Scip_Index(serializedBytes: data)
                    }
                    let joiner = SymbolJoiner(files: fileRecords, symbols: symbolRecords)
                    progress?.pipelineDidStart(stage: .relationships)
                    let scipOut = timings.measure("resolve") {
                        ScipRelationshipBuilder(
                            repositoryId: repo.id, commitHash: commitHash, runId: run.id
                        ).build(index: index, joiner: joiner, files: fileRecords)
                    }
                    try timings.measure("persist.relationships") {
                        try store.insertRelationships(scipOut.relationships)
                    }
                    resolverLabel = resolver
                    scipRelationships = scipOut.relationships
                case .unavailable(let reason):
                    diagnose(
                        fileId: nil, stage: "resolution", severity: "warning",
                        code: "SCIP_UNAVAILABLE", message: reason, scope: "scip"
                    )
                }
            }

            // test mapping: tested_by (M6)
            progress?.pipelineDidStart(stage: .testMapping)
            let testedBy = timings.measure("tests") {
                TestMapper(repositoryId: repo.id, commitHash: commitHash, runId: run.id)
                    .build(
                        files: fileRecords, symbols: symbolRecords,
                        relationships: dep.relationships + scipRelationships
                    )
            }
            try store.insertRelationships(testedBy)

            try store.insertDiagnostics(diagnostics)

            let relationshipCount = dep.relationships.count + scipRelationships.count + testedBy.count

            // finalize
            progress?.pipelineDidStart(stage: .assembly)
            let finishedAt = Timestamp.now()
            var finished = run
            finished.status = AnalysisStatus.succeeded.rawValue
            finished.finishedAt = finishedAt
            finished.resolver = resolverLabel
            finished.fileCount = fileRecords.count
            finished.symbolCount = symbolRecords.count
            finished.relationshipCount = relationshipCount
            finished.diagnosticCount = diagnostics.count
            finished.stageTimings = timings.milliseconds
            try store.finishRun(finished)
            try store.setRepositoryStatus(id: repo.id, status: .succeeded, now: finishedAt)

            var exportPath: URL?
            if input.export {
                exportPath = try timings.measure("export") {
                    try CodeGraphExporter(store: store)
                        .export(to: input.outputDirectory, commitHash: commitHash)
                }
            }

            return AnalysisResult(
                repositoryId: repo.id, runId: run.id, commitHash: commitHash,
                fileCount: fileRecords.count, pythonFileCount: pythonFiles.count,
                symbolCount: symbolRecords.count, relationshipCount: relationshipCount,
                resolver: resolverLabel,
                externalDependencyCount: externalDeps.count, diagnosticCount: diagnostics.count,
                parseErrorCount: failedFileIDs.count, stageTimings: timings.milliseconds,
                databasePath: URL(fileURLWithPath: database.path), exportPath: exportPath
            )
        } catch {
            var failed = run
            failed.status = AnalysisStatus.failed.rawValue
            failed.finishedAt = Timestamp.now()
            failed.error = String(describing: error)
            failed.stageTimings = timings.milliseconds
            try? store.finishRun(failed)
            try? store.setRepositoryStatus(id: repo.id, status: .failed, now: Timestamp.now())
            throw error
        }
    }

    // MARK: helpers

    private func pyProjectName(root: URL) -> String? {
        guard let text = try? String(
            contentsOf: root.appendingPathComponent("pyproject.toml"), encoding: .utf8
        ) else { return nil }
        return PyProjectParser.projectName(tomlText: text)
    }

    private func collectExternalDependencies(
        root: URL, repo: String, commit: String, run: String
    ) throws -> [ExternalDependencyRecord] {
        let fm = FileManager.default
        var declared: [DeclaredDependency] = []

        let pyproject = root.appendingPathComponent("pyproject.toml")
        if let text = try? String(contentsOf: pyproject, encoding: .utf8),
           let parsed = try? PyProjectParser.parse(tomlText: text) {
            declared.append(contentsOf: parsed)
        }

        if let entries = try? fm.contentsOfDirectory(atPath: root.path) {
            for name in entries.sorted()
            where name.hasPrefix("requirements") && name.hasSuffix(".txt") {
                if let text = try? String(
                    contentsOf: root.appendingPathComponent(name), encoding: .utf8
                ) {
                    declared.append(contentsOf: RequirementsParser.parse(text: text))
                }
            }
        }

        var byName: [String: DeclaredDependency] = [:]
        for dep in declared {
            let key = dep.importNameGuess
            if let existing = byName[key] {
                if existing.source != .pyproject, dep.source == .pyproject {
                    byName[key] = dep
                } else if existing.versionSpec == nil, dep.versionSpec != nil {
                    byName[key] = dep
                }
            } else {
                byName[key] = dep
            }
        }

        return byName
            .map { name, dep in
                ExternalDependencyRecord(
                    id: DeterministicID.externalDependency(
                        repositoryId: repo, commitHash: commit, name: name
                    ),
                    repositoryId: repo, commitHash: commit, runId: run,
                    name: name, distribution: dep.distribution, source: dep.source.rawValue,
                    versionSpec: dep.versionSpec, isStdlib: false, importCount: 0
                )
            }
            .sorted { $0.name < $1.name }
    }
}
