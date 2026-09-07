import Foundation
import Observation

/// What a completed analysis leaves the app with -- Docs/05 Stage 1's header bullets
/// (repository identity, detected languages, file count, readiness), read from
/// `OrionCodeIntel.AnalysisResult` by M2's `AnalysisRunner`.
struct RepositorySummary: Equatable {
    let repoRoot: URL
    let outputDirectory: URL
    let languages: [String]
    let fileCount: Int
    let symbolCount: Int
    let relationshipCount: Int
    let resolver: String
    let parseErrorCount: Int
    let diagnosticCount: Int
    let totalDurationMs: Double
}

/// One repository's lifecycle in the app. Docs/13_phase4_architecture_ui.md M1 defines and
/// tests the full state machine (`idle -> opening -> analyzing -> ready`, with `failed` reachable
/// from any step) even though only `idle`/`opening`/`analyzing`/`failed` are reachable through
/// real code yet -- `analysisSucceeded`/`analysisFailed` are the seam M2's `AnalysisRunner` will
/// drive from the outside once `AnalysisPipeline` is actually wired in, the same way this
/// session already drives `opening` from real local-path validation / `RepositoryCloner`.
@Observable
final class RepositorySession {
    enum Input: Equatable {
        case localPath(URL)
        case gitHubURL(URL)
    }

    enum State: Equatable {
        case idle
        case opening(Input)
        case analyzing
        case ready(RepositorySummary)
        case failed(String)
    }

    enum SessionError: Error, CustomStringConvertible, Equatable {
        case pathNotFound(String)
        case notADirectory(String)

        var description: String {
            switch self {
            case .pathNotFound(let path): return "no such file or directory: \(path)"
            case .notADirectory(let path): return "not a directory: \(path)"
            }
        }
    }

    private(set) var state: State = .idle
    private let cloner: RepositoryCloning
    private let fileManager: FileManager

    /// Set once opening succeeds -- M2's `AnalysisRunner` reads this to know what to analyze.
    private(set) var resolvedRepoRoot: URL?

    init(cloner: RepositoryCloning = RepositoryCloner(), fileManager: FileManager = .default) {
        self.cloner = cloner
        self.fileManager = fileManager
    }

    /// Resolves `input` to a local checkout: validates a local path exists and is a directory,
    /// or clones a GitHub URL via `cloner`. Moves to `.analyzing` on success -- M2's
    /// `AnalysisRunner` is what actually starts analyzing and eventually calls
    /// `analysisSucceeded`/`analysisFailed`; this method's own job ends at the handoff.
    func open(_ input: Input) async {
        state = .opening(input)
        do {
            let repoRoot = try await resolveLocalPath(for: input)
            resolvedRepoRoot = repoRoot
            state = .analyzing
        } catch {
            state = .failed(String(describing: error))
        }
    }

    /// M2's `AnalysisRunner` calls this once `AnalysisPipeline.run` succeeds.
    func analysisSucceeded(_ summary: RepositorySummary) {
        state = .ready(summary)
    }

    /// M2's `AnalysisRunner` calls this if the pipeline throws, times out, or is otherwise
    /// unable to produce a result.
    func analysisFailed(_ message: String) {
        state = .failed(message)
    }

    /// Back to `.idle` -- e.g. the user closes the current repository to open a different one.
    func reset() {
        state = .idle
        resolvedRepoRoot = nil
    }

    private func resolveLocalPath(for input: Input) async throws -> URL {
        switch input {
        case .localPath(let url):
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
                throw SessionError.pathNotFound(url.path)
            }
            guard isDirectory.boolValue else {
                throw SessionError.notADirectory(url.path)
            }
            return url
        case .gitHubURL(let url):
            return try await cloner.clone(url: url)
        }
    }
}

extension RepositorySession {
    /// `orion-index`'s own `--out` default (`<path>/.orion`) -- reused as-is so a repository
    /// already analyzed via the CLI is picked up by the app with no re-analysis, per Docs/13's
    /// own decision. Applies uniformly to a cloned checkout too: the clone destination *is* the
    /// local path from here on, nothing app-specific nests under it beyond the same `.orion`.
    static func outputDirectory(forRepoRoot repoRoot: URL) -> URL {
        repoRoot.appendingPathComponent(".orion", isDirectory: true)
    }
}
