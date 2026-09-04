import Foundation

/// Serializes a run's Code Graph to `<outDir>/export/`: `repository.json`, `files.jsonl`,
/// `symbols.jsonl`, `relationships.jsonl`, `external_dependencies.jsonl`,
/// `diagnostics.jsonl`, and the compact `code_graph.json` skeleton. Reads straight from the
/// DB so `orion-index export` can regenerate without re-analyzing.
public struct CodeGraphExporter {
    public let store: Store

    public init(store: Store) { self.store = store }

    public enum ExportError: Error, CustomStringConvertible {
        case noRun
        public var description: String { "no analysis run found in the database" }
    }

    @discardableResult
    public func export(to outDir: URL, commitHash: String? = nil) throws -> URL {
        guard let run = try store.latestRun(commitHash: commitHash) else { throw ExportError.noRun }
        let repo = try store.repository(id: run.repositoryId)
        let files = try store.files(runId: run.id)
        let symbols = try store.symbols(runId: run.id)
        let rels = try store.relationships(runId: run.id)
        let extDeps = try store.externalDependencies(runId: run.id)
        let diags = try store.diagnostics(runId: run.id)

        let exportDir = outDir.appendingPathComponent("export")
        try FileManager.default.createDirectory(at: exportDir, withIntermediateDirectories: true)

        let model = CodeGraphModel(
            run: run, repo: repo, files: files, symbols: symbols,
            relationships: rels, externalDependencies: extDeps, diagnostics: diags
        )

        try write(model.repositoryExport(), to: exportDir.appendingPathComponent("repository.json"))
        try writeJSONL(model.fileExports(), to: exportDir.appendingPathComponent("files.jsonl"))
        try writeJSONL(model.symbolExports(), to: exportDir.appendingPathComponent("symbols.jsonl"))
        try writeJSONL(model.relationshipExports(), to: exportDir.appendingPathComponent("relationships.jsonl"))
        try writeJSONL(model.externalDependencyExports(), to: exportDir.appendingPathComponent("external_dependencies.jsonl"))
        try writeJSONL(model.diagnosticExports(), to: exportDir.appendingPathComponent("diagnostics.jsonl"))
        try write(model.codeGraphExport(), to: exportDir.appendingPathComponent("code_graph.json"))

        return exportDir
    }

    // MARK: writers

    private func encoder(pretty: Bool) -> JSONEncoder {
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        e.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
                                    : [.sortedKeys, .withoutEscapingSlashes]
        return e
    }

    private func write<T: Encodable>(_ value: T, to url: URL) throws {
        try encoder(pretty: true).encode(value).write(to: url)
    }

    private func writeJSONL<T: Encodable>(_ values: [T], to url: URL) throws {
        let enc = encoder(pretty: false)
        var data = Data()
        for value in values {
            data.append(try enc.encode(value))
            data.append(0x0A)
        }
        try data.write(to: url)
    }
}
