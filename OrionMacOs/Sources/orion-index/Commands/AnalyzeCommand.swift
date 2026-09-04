import ArgumentParser
import Foundation

struct Analyze: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "analyze",
        abstract: "Analyze a repository checkout and build its Code Graph."
    )

    @Argument(help: "Path to a local repository checkout.")
    var path: String

    @Option(help: "Checkout this commit before analyzing (restored on exit).")
    var commit: String?

    @Option(help: "Output directory for orion.db + export/ (default: <path>/.orion).")
    var out: String?

    @Flag(inversion: .prefixedNo, help: "Write the JSON/JSONL export.")
    var export: Bool = true

    @Option(help: "Source language (only 'python' is supported in Phase 1).")
    var language: String = "python"

    @Option(help: "Parallel parse workers (default: active processor count).")
    var jobs: Int?

    @Flag(help: "Drop any prior run for this (repo, commit) before analyzing.")
    var clean: Bool = false

    @Option(help: "Recorded on the repositories row.")
    var sourceURL: String?

    @Flag(help: "Exit non-zero if any file fails to parse.")
    var failOnParseError: Bool = false

    @Option(help: "Skip files larger than this many bytes.")
    var maxFileBytes: Int = 2_000_000

    func run() throws {
        throw NotImplemented(milestone: "M1–M7")
    }
}
