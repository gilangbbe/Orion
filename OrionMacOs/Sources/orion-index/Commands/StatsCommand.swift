import ArgumentParser
import Foundation
import OrionCodeIntel

struct Stats: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "stats",
        abstract: "Print counts and timings for the latest run in a Code Graph DB."
    )

    @Option(help: "Path to orion.db (or pass --out).")
    var db: String?

    @Option(help: "Output directory containing orion.db.")
    var out: String?

    @Option(help: "Restrict to this commit.")
    var commit: String?

    @Flag(help: "Emit a single JSON object instead of a table.")
    var json: Bool = false

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

        let database = try OrionDatabase(path: dbPath)
        let report = try StatsReporter.build(database: database, commitHash: commit)

        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(report)
            print(String(decoding: data, as: UTF8.self))
            return
        }

        guard let runId = report.runId else {
            print("no runs in \(dbPath)")
            return
        }
        print("""
        db:         \(report.databasePath)
        repo:       \(report.localPath ?? "?")  @ \(report.commitHash ?? "?")
        run:        \(runId)  [\(report.status ?? "?")]  \(report.startedAt ?? "")
        resolver:   \(report.resolver ?? "?")
        files:      \(report.fileCount) total, \(report.pythonFileCount) python, \(report.parseOkCount) parse-ok
        by language: \(report.filesByLanguage.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))
        ext deps:   \(report.externalDependencyCount)
        symbols:    \(report.symbolCount)
        relations:  \(report.relationshipCount)
        diagnostics:\(report.diagnosticCount)
        timings ms: \(report.stageTimingsMs.sorted { $0.key < $1.key }.map { "\($0.key)=\(String(format: "%.0f", $0.value))" }.joined(separator: " "))
        """)
    }
}
