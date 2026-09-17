import ArgumentParser
import Foundation
import OrionCodeIntel

/// Docs/17_phase7_teaching_mode.md §14 M1 — a debug/inspection surface for `ConceptExtractor`,
/// mirroring Phase 3 M1's `orion-agent classify`: it exists to exercise the extraction end to
/// end before the agent / app that will really drive it (M5/M6). A pure `Store` read/write like
/// `revisions`, so it follows the same `--db` / `--out` convention rather than a positional path.
struct TeachConcepts: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "teach-concepts",
        abstract: "Derive (with --extract) and list the repository's Teaching Mode concepts."
    )

    @Option(help: "Path to orion.db (or pass --out).")
    var db: String?

    @Option(help: "Output directory containing orion.db.")
    var out: String?

    @Option(help: "Restrict to this commit's latest run.")
    var commit: String?

    @Option(help: "Top-N concepts to keep, by centrality (Docs/17 Decision 9).")
    var cap: Int = ConceptExtractor.defaultCap

    @Flag(help: "Run ConceptExtractor first (derive + reconcile), then list. Without this, only lists what's already stored.")
    var extract: Bool = false

    @Flag(help: "Include stale concepts in the listing.")
    var includeStale: Bool = false

    @Flag(help: "Order by TeachingPlanner rank (mastery × centrality, misconception boost) and show p_mastered.")
    var plan: Bool = false

    @Option(help: "Developer id for --plan mastery lookup (default: local).")
    var developer: String = "local"

    @Flag(help: "Emit JSON instead of text.")
    var json: Bool = false

    private struct ConceptJSON: Encodable {
        var id, kind, subjectLabel: String
        var difficultyBand: Int
        var centrality: Double
        var stale: Bool
        var sourceComponentId, sourceClaimId: String?
        var evidenceAnchors: [String]
    }
    private struct ReportJSON: Encodable {
        var extracted: Bool
        var inserted, restaled, revived, deduped, cappedOut, kept: Int
        var concepts: [ConceptJSON]
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

        var summary = (inserted: 0, restaled: 0, revived: 0, deduped: 0, cappedOut: 0, kept: 0)
        if extract {
            let r = try ConceptExtractor.extract(
                store: store, commitHash: commit, cap: cap,
                now: ISO8601DateFormatter().string(from: Date()))
            summary = (r.inserted.count, r.restaled.count, r.revived.count, r.deduped,
                       r.cappedOut, r.kept)
        }

        let concepts = try store.teachingConcepts(
            repositoryId: run.repositoryId, includeStale: includeStale)

        if json {
            let payload = ReportJSON(
                extracted: extract, inserted: summary.inserted, restaled: summary.restaled,
                revived: summary.revived, deduped: summary.deduped, cappedOut: summary.cappedOut,
                kept: summary.kept,
                concepts: concepts.map {
                    ConceptJSON(
                        id: $0.id, kind: $0.kind, subjectLabel: $0.subjectLabel,
                        difficultyBand: $0.difficultyBand, centrality: $0.centrality,
                        stale: $0.stale, sourceComponentId: $0.sourceComponentId,
                        sourceClaimId: $0.sourceClaimId, evidenceAnchors: $0.evidenceAnchors)
                })
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.keyEncodingStrategy = .convertToSnakeCase
            print(String(decoding: try encoder.encode(payload), as: UTF8.self))
            return
        }

        if extract {
            print("""
            extraction: \(summary.inserted) inserted, \(summary.revived) revived, \
            \(summary.restaled) re-staled, \(summary.deduped) deduped, \
            \(summary.cappedOut) over cap — \(summary.kept) active concept(s)
            """)
        }
        guard !concepts.isEmpty else {
            print("no teaching concepts\(extract ? "" : " yet — run with --extract")")
            return
        }

        if plan {
            let ranked = try TeachingPlanner(store: store)
                .rank(repositoryId: run.repositoryId, developerId: developer)
            for r in ranked {
                let m = r.hasOpenMisconception ? " ⚠misconception" : ""
                print(String(
                    format: "  score=%.3f  p=%.2f  n=%d  [band %d] %@ · %@%@",
                    r.score, r.pMastered, r.attemptsCount, r.concept.difficultyBand,
                    r.concept.kind, r.concept.subjectLabel, m))
            }
            return
        }

        for c in concepts {
            let flag = c.stale ? " [stale]" : ""
            print(String(
                format: "  [band %d  c=%.3f] %@ · %@%@",
                c.difficultyBand, c.centrality, c.kind, c.subjectLabel, flag))
        }
    }
}
