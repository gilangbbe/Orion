import ArgumentParser
import Foundation
import OrionCodeIntel

/// `orion-index snapshot` (Docs/19 M2): packs the Codebase Model the Mac app shows for a repository
/// into a knowledge snapshot for the iOS companion.
struct Snapshot: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "snapshot",
        abstract: "Build a knowledge snapshot (.orionsnap + manifest) for the iOS companion.",
        discussion: """
            Keeps the analysis run the Mac app shows (the latest succeeded one, or --commit's), its \
            semantic model, revisions, teaching concepts and verified questions, plus the source lines \
            its evidence views cite. Drops other runs, the Mac's own learning progress and ask \
            sessions, and Mac-only traces.
            """
    )

    @Argument(help: "Path to the analyzed repository checkout.")
    var path: String

    @Option(help: "Directory containing orion.db (default: <path>/.orion).")
    var out: String?

    @Option(help: "Where to write the snapshot (default: <out>/snapshot).")
    var destination: String?

    @Option(help: "Snapshot this commit's run instead of the latest succeeded one.")
    var commit: String?

    @Flag(help: "Print the manifest as JSON.")
    var json = false

    func run() throws {
        let repoRoot = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
        let outDir = out.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            ?? repoRoot.appendingPathComponent(".orion", isDirectory: true)
        let dbPath = outDir.appendingPathComponent("orion.db")
        guard FileManager.default.fileExists(atPath: dbPath.path) else {
            throw ValidationError("no database at \(dbPath.path) -- run `orion-index analyze` first")
        }
        let destinationDir = destination.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            ?? outDir.appendingPathComponent("snapshot", isDirectory: true)

        let builder = KnowledgeSnapshotBuilder(databasePath: dbPath, repoRoot: repoRoot, commit: commit)
        let output = try builder.build(to: destinationDir)
        let manifest = output.manifest

        if json {
            print(String(decoding: try manifest.json(), as: UTF8.self))
            return
        }
        let c = manifest.counts
        let mb = { (bytes: Int?) in String(format: "%.2f MB", Double(bytes ?? 0) / 1_048_576) }
        print("wrote \(output.snapshotURL.path)")
        print("  \(mb(manifest.snapshotByteCount)) compressed (\(mb(manifest.databaseByteCount)) database)")
        print("  \(manifest.repositoryName) @ \(manifest.commitHash.prefix(12)), run \(manifest.runId)")
        print("  \(c.files) files, \(c.symbols) symbols, \(c.relationships) relationships")
        print("  \(c.components) components, \(c.claims) claims, \(c.evidence) evidence, \(c.modelRevisions) revisions")
        print("  \(c.teachingConcepts) teaching concepts, \(c.teachingQuestions) verified questions")
        print("  \(c.snippets) evidence snippets, \(c.snippetsSkipped) cited ranges skipped")
        print("manifest: \(output.manifestURL.path)")
    }
}
