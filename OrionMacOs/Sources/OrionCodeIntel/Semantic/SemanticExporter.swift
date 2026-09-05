import Foundation

/// Serializes the run's latest investigation to `<outDir>/export/`: `components.jsonl`,
/// `claims.jsonl`, `evidence.jsonl`, `investigations.jsonl` (full history for the run), and the
/// compact `semantic_model.json` skeleton (Docs/11 M3). Reads straight from the DB, mirroring
/// `CodeGraphExporter`, so both `orion-index export` and `ingest-semantic --export` can
/// regenerate it without re-ingesting. Phase 1's own export files are untouched either way —
/// additive, same as the `v2_phase2_schema` migration.
public struct SemanticExporter {
    public let store: Store
    public init(store: Store) { self.store = store }

    /// `nil` (writes nothing) when the run has no investigation yet — not an error, just
    /// nothing to export. `orion-index export` treats that as the normal Phase-1-only case.
    @discardableResult
    public func export(to outDir: URL, commitHash: String? = nil) throws -> URL? {
        guard let run = try store.latestRun(commitHash: commitHash) else { return nil }
        guard let investigation = try store.latestInvestigation(runId: run.id) else { return nil }

        let allInvestigations = try store.investigations(runId: run.id)
        let components = try store.components(investigationId: investigation.id)
        let componentMembers = try store.componentMembers(componentIds: components.map(\.id))
        let componentRelationships = try store.componentRelationships(investigationId: investigation.id)
        let claims = try store.claims(investigationId: investigation.id)
        let evidence = try store.evidence(claimIds: claims.map(\.id))
        let anchorBySymbolId = Dictionary(
            uniqueKeysWithValues: try store.symbols(runId: run.id).map { ($0.id, $0.anchor) }
        )

        let model = SemanticModel(
            investigation: investigation, components: components,
            componentMembers: componentMembers, componentRelationships: componentRelationships,
            claims: claims, evidence: evidence, allInvestigations: allInvestigations,
            anchorBySymbolId: anchorBySymbolId
        )

        let exportDir = outDir.appendingPathComponent("export")
        try FileManager.default.createDirectory(at: exportDir, withIntermediateDirectories: true)

        try writeJSONL(model.componentExports(), to: exportDir.appendingPathComponent("components.jsonl"))
        try writeJSONL(model.claimExports(), to: exportDir.appendingPathComponent("claims.jsonl"))
        try writeJSONL(model.evidenceExports(), to: exportDir.appendingPathComponent("evidence.jsonl"))
        try writeJSONL(
            model.investigationExports(), to: exportDir.appendingPathComponent("investigations.jsonl")
        )
        try write(model.semanticModelExport(), to: exportDir.appendingPathComponent("semantic_model.json"))

        return exportDir
    }

    // MARK: writers (mirrors CodeGraphExporter)

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
