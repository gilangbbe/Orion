import ArgumentParser
import Foundation
import OrionCodeIntel

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

    @Option(name: .customLong("source-url"), help: "Recorded on the repositories row.")
    var sourceURL: String?

    @Flag(help: "Exit non-zero if any file fails to parse.")
    var failOnParseError: Bool = false

    @Flag(inversion: .prefixedNo, help: "Run the scip-python resolution stage (calls/extends/implements).")
    var resolve: Bool = true

    @Option(help: "Skip files larger than this many bytes.")
    var maxFileBytes: Int = 2_000_000

    func run() throws {
        guard let language = SourceLanguage(rawValue: language) else {
            throw PipelineError.unsupportedLanguage(language)
        }

        let repoURL = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            .standardizedFileURL
        let outURL = URL(
            fileURLWithPath: ((out ?? repoURL.appendingPathComponent(".orion").path) as NSString)
                .expandingTildeInPath
        ).standardizedFileURL
        try FileManager.default.createDirectory(at: outURL, withIntermediateDirectories: true)

        let database = try OrionDatabase(path: outURL.appendingPathComponent("orion.db").path)
        let pipeline = AnalysisPipeline(database: database)

        let input = AnalysisInput(
            repoPath: repoURL, explicitCommit: commit, sourceURL: sourceURL,
            outputDirectory: outURL, language: language, clean: clean,
            maxFileBytes: maxFileBytes, failOnParseError: failOnParseError, jobs: jobs,
            resolve: resolve, export: export
        )

        let result: AnalysisResult
        do {
            result = try pipeline.run(input)
        } catch let error as ValidationError {
            throw error                      // usage error → ArgumentParser exit code
        } catch {
            FileHandle.standardError.write(Data("analysis failed: \(error)\n".utf8))
            throw ExitCode(3)
        }

        let totalMs = result.stageTimings.values.reduce(0, +)
        print("""
        analyzed \(repoURL.path)
          commit:      \(result.commitHash)
          files:       \(result.fileCount) (\(result.pythonFileCount) python)
          symbols:     \(result.symbolCount)
          relations:   \(result.relationshipCount)
          resolver:    \(result.resolver)
          parse errors:\(result.parseErrorCount)
          ext deps:    \(result.externalDependencyCount)
          diags:       \(result.diagnosticCount)
          db:          \(result.databasePath.path)
          time:        \(String(format: "%.0f", totalMs)) ms
        """)

        if let exportPath = result.exportPath {
            print("  export:      \(exportPath.path)")
        }
        if failOnParseError, result.parseErrorCount > 0 {
            throw ExitCode(4)
        }
    }
}
