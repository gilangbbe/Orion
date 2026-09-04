import ArgumentParser
import Foundation
import OrionCodeIntel

struct Export: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "export",
        abstract: "Re-serialize export/ from an existing Code Graph DB without re-analyzing."
    )

    @Option(help: "Path to orion.db (or pass --out).")
    var db: String?

    @Option(help: "Output directory containing orion.db; export/ is written alongside it.")
    var out: String?

    @Option(help: "Restrict to this commit.")
    var commit: String?

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
        let exportDir = try CodeGraphExporter(store: Store(database))
            .export(to: outDir, commitHash: commit)
        print("wrote \(exportDir.path)")
    }
}
