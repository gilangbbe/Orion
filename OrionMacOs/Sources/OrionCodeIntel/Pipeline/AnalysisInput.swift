import Foundation

public struct AnalysisInput {
    public var repoPath: URL
    public var explicitCommit: String?
    public var sourceURL: String?
    public var outputDirectory: URL
    public var language: SourceLanguage
    public var clean: Bool
    public var maxFileBytes: Int
    public var failOnParseError: Bool
    /// Parallel parse workers; `nil` = active processor count, `1` = deterministic sequential.
    public var jobs: Int?
    /// Run the SCIP (`scip-python`) resolution stage. When false, or when the tool is
    /// unavailable, no `calls`/`extends`/`implements` edges are produced.
    public var resolve: Bool
    /// Write the JSON/JSONL Code Graph export to `<outputDirectory>/export/`.
    public var export: Bool

    public init(
        repoPath: URL, explicitCommit: String? = nil, sourceURL: String? = nil,
        outputDirectory: URL, language: SourceLanguage = .python, clean: Bool = false,
        maxFileBytes: Int = 2_000_000, failOnParseError: Bool = false, jobs: Int? = nil,
        resolve: Bool = true, export: Bool = true
    ) {
        self.repoPath = repoPath
        self.explicitCommit = explicitCommit
        self.sourceURL = sourceURL
        self.outputDirectory = outputDirectory
        self.language = language
        self.clean = clean
        self.maxFileBytes = maxFileBytes
        self.failOnParseError = failOnParseError
        self.jobs = jobs
        self.resolve = resolve
        self.export = export
    }

    public var databasePath: URL { outputDirectory.appendingPathComponent("orion.db") }
}

public struct AnalysisResult {
    public var repositoryId: String
    public var runId: String
    public var commitHash: String
    public var fileCount: Int
    public var pythonFileCount: Int
    public var symbolCount: Int
    public var relationshipCount: Int
    public var resolver: String
    public var externalDependencyCount: Int
    public var diagnosticCount: Int
    public var parseErrorCount: Int
    public var stageTimings: [String: Double]
    public var databasePath: URL
    public var exportPath: URL?
}

public enum PipelineError: Error, CustomStringConvertible {
    case notADirectory(String)
    case unsupportedLanguage(String)

    public var description: String {
        switch self {
        case .notADirectory(let p): return "not a directory: \(p)"
        case .unsupportedLanguage(let l): return "unsupported language for Phase 1: \(l)"
        }
    }
}
