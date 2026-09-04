import ArgumentParser
import Foundation
import OrionCodeIntel

struct Query: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "query",
        abstract: "Ad-hoc read-only lookups over a Code Graph DB (debugging aid)."
    )

    @Option(help: "Path to orion.db (or pass --out).")
    var db: String?

    @Option(help: "Output directory containing orion.db.")
    var out: String?

    @Option(help: "Restrict to this commit.")
    var commit: String?

    @Option(help: "Fuzzy-match symbols by anchor / qualified name.")
    var symbol: String?

    @Option(help: "Anchor to list inbound edges for (who references it).")
    var callers: String?

    @Option(help: "Anchor to list outbound edges for (what it references).")
    var callees: String?

    @Option(help: "Dotted module path to list the symbols of.")
    var module: String?

    @Option(help: "Max rows.")
    var limit: Int = 50

    @Flag(help: "Emit JSON instead of text.")
    var json: Bool = false

    func run() throws {
        let modes = [symbol, callers, callees, module].compactMap { $0 }
        guard modes.count == 1 else {
            throw ValidationError("pass exactly one of --symbol / --callers / --callees / --module")
        }

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

        let engine = QueryEngine(try OrionDatabase(path: dbPath))

        if let symbol {
            try emit(engine.findSymbols(matching: symbol, commit: commit, limit: limit)) {
                "\($0.kind.padding(toLength: 10, withPad: " ", startingAt: 0)) \($0.anchor)  "
                    + "(\($0.file):\($0.startLine)-\($0.endLine))\($0.isExported ? "" : "  [not exported]")"
            }
        } else if let module {
            try emit(engine.moduleSymbols(module, commit: commit, limit: limit)) {
                "\($0.kind.padding(toLength: 10, withPad: " ", startingAt: 0)) \($0.anchor)"
            }
        } else if let callers {
            try emit(engine.callers(of: callers, commit: commit, limit: limit)) {
                "\($0.type.padding(toLength: 12, withPad: " ", startingAt: 0)) "
                    + "\($0.anchor ?? $0.ref ?? "?")\($0.external ? "  [external]" : "")"
                    + ($0.siteLine.map { "  :\($0)" } ?? "")
            }
        } else if let callees {
            try emit(engine.callees(of: callees, commit: commit, limit: limit)) {
                "\($0.type.padding(toLength: 12, withPad: " ", startingAt: 0)) "
                    + "\($0.anchor ?? $0.ref ?? "?")\($0.external ? "  [external]" : "")"
                    + ($0.siteLine.map { "  :\($0)" } ?? "")
            }
        }
    }

    private func emit<T: Encodable>(_ rows: [T], line: (T) -> String) throws {
        if json {
            let enc = JSONEncoder()
            enc.keyEncodingStrategy = .convertToSnakeCase
            enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            print(String(decoding: try enc.encode(rows), as: UTF8.self))
        } else if rows.isEmpty {
            print("(no matches)")
        } else {
            rows.forEach { print(line($0)) }
        }
    }
}
