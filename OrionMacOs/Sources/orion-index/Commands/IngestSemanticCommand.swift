import ArgumentParser
import Foundation
import OrionCodeIntel

/// Runs the full Docs/11 validation pipeline (schema -> evidence -> consistency -> Codebase
/// Model update -> export) over a Claude Code candidate and persists the result.
struct IngestSemantic: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ingest-semantic",
        abstract: "Validate + persist a Claude Code semantic-findings JSON into the Codebase Model (Phase 2)."
    )

    @Argument(help: "Path to a semantic_findings.json candidate (Docs/11 structured output contract).")
    var path: String

    @Option(help: "Path to investigation_meta.json (model/session/cost/turns) written alongside the candidate.")
    var meta: String?

    @Option(help: "Path to orion.db (or pass --out).")
    var db: String?

    @Option(help: "Output directory containing orion.db; export/ is written alongside it.")
    var out: String?

    @Option(help: "Restrict to this commit.")
    var commit: String?

    @Flag(inversion: .prefixedNo, help: "Write the semantic export files (components/claims/evidence/investigations.jsonl, semantic_model.json) after ingesting.")
    var export: Bool = true

    func run() throws {
        let dbPath: String
        let outDir: URL
        if let db {
            dbPath = (db as NSString).expandingTildeInPath
            outDir = URL(fileURLWithPath: dbPath).deletingLastPathComponent()
        } else if let out {
            outDir = URL(fileURLWithPath: (out as NSString).expandingTildeInPath)
            dbPath = outDir.appendingPathComponent("orion.db").path
        } else {
            throw ValidationError("pass --db <orion.db> or --out <dir>")
        }
        guard FileManager.default.fileExists(atPath: dbPath) else {
            throw ValidationError("no database at \(dbPath)")
        }

        let database = try OrionDatabase(path: dbPath)
        let store = Store(database)
        guard let run = try store.latestRun(commitHash: commit) else {
            throw ValidationError("no analysis run in \(dbPath) to attach semantic findings to")
        }

        let candidateURL = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        let metaURL = meta.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
        let importer = SemanticImporter(store: store)

        do {
            let outcome = try importer.ingest(
                candidateURL: candidateURL, metaURL: metaURL, run: run, now: Timestamp.now()
            )
            printSummary(outcome, candidateURL: candidateURL, run: run)
            try maybeExport(store: store, outDir: outDir)
            if outcome.investigation.outcome == InvestigationOutcome.rejected.rawValue
                || outcome.investigation.outcome == InvestigationOutcome.unverified.rawValue
            {
                throw ExitCode(1)
            }
        } catch let error as SemanticImportError {
            // Even a rejected attempt persisted an investigations row -- export it too, so
            // the rejection itself is visible in investigations.jsonl.
            print("rejected: \(error)")
            try maybeExport(store: store, outDir: outDir)
            throw ExitCode(1)
        }
    }

    private func maybeExport(store: Store, outDir: URL) throws {
        guard export else { return }
        if let exportDir = try SemanticExporter(store: store).export(to: outDir, commitHash: commit) {
            print("  wrote \(exportDir.path)")
        }
    }

    private func printSummary(
        _ outcome: SemanticIngestOutcome, candidateURL: URL, run: AnalysisRunRecord
    ) {
        let c = outcome.consistent
        let inv = outcome.investigation
        print("""
        ingested \(candidateURL.lastPathComponent) into run \(run.id)
          investigation:            \(inv.id)  outcome=\(inv.outcome)
          components:               \(c.components.count) persisted, \
        \(c.droppedComponents.count) dropped, \(c.duplicateComponentsDropped.count) duplicate
          component_relationships:  \(c.componentRelationships.count) persisted \
        (\(c.componentRelationships.filter { $0.confidenceTier == .unresolved }.count) unconfirmed), \
        \(c.droppedComponentRelationships.count) dropped
          claims:                   \(c.claims.count) persisted \
        (\(c.claims.filter { $0.claimType == .contradicted }.count) contradicted), \
        \(c.droppedClaims.count) dropped
          diagnostics:              \(c.diagnostics.count)
        """)
    }
}
