import ArgumentParser

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
        throw NotImplemented(milestone: "M1")
    }
}
