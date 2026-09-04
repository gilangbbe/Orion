import ArgumentParser

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
        throw NotImplemented(milestone: "M7")
    }
}
