import ArgumentParser
import Foundation
import OrionCodeIntel

/// Docs/16_phase6_continuous_model_updates.md §7. A pure `Store` read, like `stats`/`query` —
/// so it follows their own `--db`/`--out` convention, **not** the positional `<path>` this
/// command's own plan originally sketched (only `analyze` takes a repo checkout path; every
/// other read-only command here reads an already-built `orion.db`, found by checking the actual
/// existing commands rather than the plan's own guess).
struct Revisions: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "revisions",
        abstract: "Print the repository's model-revision history (\"Understanding updated\")."
    )

    @Option(help: "Path to orion.db (or pass --out).")
    var db: String?

    @Option(help: "Output directory containing orion.db.")
    var out: String?

    @Option(help: "Restrict to this commit.")
    var commit: String?

    @Option(help: "Only show revisions newer than this revision number.")
    var since: Int?

    /// Docs/16 M6: real Phase 2/3 investigation history predates `RevisionDiffer` ever being
    /// wired into `ingest()`/`ingestAnswer()` (M4) -- a repository investigated before this
    /// migration exists has real investigations with no revision to show for them at all.
    /// `--backfill` computes and persists them retroactively, dated to each investigation's own
    /// `createdAt` rather than "now" (`SemanticImporter.backfillModelRevisions`), then falls
    /// through to the normal listing so the result is visible immediately.
    @Flag(help: "Compute and persist revisions for any past investigation that doesn't have one yet.")
    var backfill: Bool = false

    @Flag(help: "Emit JSON instead of text.")
    var json: Bool = false

    private struct EntryJSON: Encodable {
        var id, entityType, changeType, subjectLabel, reason: String
        var confidenceTier: String?
        var relatedClaimId: String?
        var previousState: String?
        var newState: String?
    }
    private struct RevisionJSON: Encodable {
        var id: String
        var revisionNumber: Int
        var previousRevision: String?
        var changeSummary: String
        var triggeringInvestigationId: String?
        var createdAt: String
        var entries: [EntryJSON]
    }

    func run() throws {
        let dbPath: String
        if let db {
            dbPath = (db as NSString).expandingTildeInPath
        } else if let out {
            dbPath = URL(fileURLWithPath: (out as NSString).expandingTildeInPath)
                .appendingPathComponent("orion.db").path
        } else {
            throw ValidationError("pass --db <orion.db> or --out <dir>")
        }
        guard FileManager.default.fileExists(atPath: dbPath) else {
            throw ValidationError("no database at \(dbPath)")
        }

        let store = Store(try OrionDatabase(path: dbPath))
        guard let run = try store.latestRun(commitHash: commit) else {
            print("no runs in \(dbPath)")
            return
        }

        if backfill {
            let allInvestigations = try store.investigations(repositoryId: run.repositoryId)
            // "Covered" means a *structured* revision exists (>= 1 model_revision_entries row) --
            // not just any model_revisions row. Real finding (Docs/16 M6): a repository ingested
            // under Phase 2/3's old unconditional-write behavior already has one coarse,
            // entry-less `model_revisions` row per investigation, each with a real
            // `triggering_investigation_id` already set -- an id-only coverage check reads every
            // one of those as "already backfilled" and silently no-ops on exactly the databases
            // this flag exists to help.
            var covered = Set<String>()
            for revision in try store.modelRevisions(repositoryId: run.repositoryId) {
                guard let triggering = revision.triggeringInvestigationId else { continue }
                if try !store.modelRevisionEntries(modelRevisionId: revision.id).isEmpty {
                    covered.insert(triggering)
                }
            }
            let toBackfill = allInvestigations.filter { !covered.contains($0.id) }
            let created = try SemanticImporter(store: store)
                .backfillModelRevisions(investigations: toBackfill, run: run)
            print("backfill: \(toBackfill.count) investigation(s) checked, \(created) revision(s) created")
        }

        var revisions = try store.modelRevisions(repositoryId: run.repositoryId)
        if let since {
            revisions = revisions.filter { $0.revisionNumber > since }
        }

        if json {
            let payload = try revisions.map { revision -> RevisionJSON in
                let entries = try store.modelRevisionEntries(modelRevisionId: revision.id)
                    .map { e in
                        EntryJSON(
                            id: e.id, entityType: e.entityType, changeType: e.changeType,
                            subjectLabel: e.subjectLabel, reason: e.reason,
                            confidenceTier: e.confidenceTier, relatedClaimId: e.relatedClaimId,
                            previousState: e.previousStateJson, newState: e.newStateJson
                        )
                    }
                return RevisionJSON(
                    id: revision.id, revisionNumber: revision.revisionNumber,
                    previousRevision: revision.previousRevision, changeSummary: revision.changeSummary,
                    triggeringInvestigationId: revision.triggeringInvestigationId,
                    createdAt: revision.createdAt, entries: entries
                )
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.keyEncodingStrategy = .convertToSnakeCase
            print(String(decoding: try encoder.encode(payload), as: UTF8.self))
            return
        }

        guard !revisions.isEmpty else {
            print(since == nil ? "no revisions yet for \(dbPath)" : "no revisions newer than \(since!)")
            return
        }

        for revision in revisions {
            print("Revision \(revision.revisionNumber)  \(revision.createdAt)")
            print("  \(revision.changeSummary)")
            for entry in try store.modelRevisionEntries(modelRevisionId: revision.id) {
                print("    [\(entry.entityType)/\(entry.changeType)] \(entry.subjectLabel)")
                print("      \(entry.reason)")
            }
        }
    }
}
