import Foundation
import OrionCodeIntel

/// Docs/13_phase4_architecture_ui.md M2: drives `OrionCodeIntel.AnalysisPipeline` on a
/// background task, reporting into an `AnalysisProgressTracker` as it goes, then drives
/// `session` to `.ready`/`.failed` -- the seam M1's `RepositorySession.open(_:)` deliberately
/// left for this milestone ("M1's own job ends at the handoff").
enum AnalysisRunner {
    /// - Parameter resolve: forwarded to `AnalysisInput.resolve` -- the SCIP (`scip-python`/`npx`)
    ///   stage. Defaults to `true`, matching `orion-index analyze`'s own default; tests pass
    ///   `false` to stay fast and network-free, the same reason the CLI has a `--no-resolve` flag.
    static func run(
        repoRoot: URL, session: RepositorySession, progress: AnalysisProgressTracker,
        resolve: Bool = true
    ) async {
        let outputDirectory = RepositorySession.outputDirectory(forRepoRoot: repoRoot)
        do {
            let existingCheck = Task.detached(priority: .userInitiated) {
                try existingSummary(repoRoot: repoRoot, outputDirectory: outputDirectory)
            }
            if let reused = try await existingCheck.value {
                session.analysisSucceeded(reused)
                return
            }

            let result = try await Task.detached(priority: .userInitiated) {
                try FileManager.default.createDirectory(
                    at: outputDirectory, withIntermediateDirectories: true)
                let database = try OrionDatabase(
                    path: outputDirectory.appendingPathComponent("orion.db").path)
                let pipeline = AnalysisPipeline(database: database)
                let input = AnalysisInput(
                    repoPath: repoRoot, outputDirectory: outputDirectory, resolve: resolve)
                return try pipeline.run(input, progress: progress)
            }.value

            session.analysisSucceeded(
                RepositorySummary(
                    repoRoot: repoRoot, outputDirectory: outputDirectory,
                    languages: [SourceLanguage.python.rawValue],
                    fileCount: result.fileCount, symbolCount: result.symbolCount,
                    relationshipCount: result.relationshipCount, resolver: result.resolver,
                    parseErrorCount: result.parseErrorCount,
                    diagnosticCount: result.diagnosticCount,
                    totalDurationMs: result.stageTimings.values.reduce(0, +)
                ))
        } catch {
            session.analysisFailed(String(describing: error))
        }
    }

    /// **Real bug, found live**: Phase 1's file/symbol/relationship ids are content-addressed
    /// per `(repository, commit)`, not per-run (Docs/12 M1's own manual-E2E caveat: "re-running
    /// `analyze` into the SAME `--out` for the same commit needs `--clean` first"). Blindly
    /// re-running `AnalysisPipeline` against an already-analyzed, unchanged commit throws a raw
    /// SQLite `UNIQUE constraint failed: files.id` instead of upserting -- hit for real by
    /// closing and reopening the same repository. The fix is also the better UX Docs/13 already
    /// promised ("a repo already analyzed via the CLI is picked up by the app with no
    /// re-analysis") and had never actually implemented: if a `succeeded` run already exists for
    /// the repo's current commit, reuse it instead of re-analyzing at all.
    private static func existingSummary(
        repoRoot: URL, outputDirectory: URL
    ) throws -> RepositorySummary? {
        let databasePath = outputDirectory.appendingPathComponent("orion.db")
        guard FileManager.default.fileExists(atPath: databasePath.path) else { return nil }

        let git = GitRunner(repoPath: repoRoot)
        let currentCommit = git.isRepository() ? ((try? git.headCommit()) ?? "unversioned") : "unversioned"

        let store = CodebaseModelStore(outputDirectory: outputDirectory)
        guard let run = try store.latestRun(commitHash: currentCommit),
            run.status == AnalysisStatus.succeeded.rawValue
        else { return nil }

        let languages = try store.repository(id: run.repositoryId)?.languages
            ?? [SourceLanguage.python.rawValue]
        let parseOkCount = try store.parseOkCount(runId: run.id)

        return RepositorySummary(
            repoRoot: repoRoot, outputDirectory: outputDirectory, languages: languages,
            fileCount: run.fileCount, symbolCount: run.symbolCount,
            relationshipCount: run.relationshipCount, resolver: run.resolver,
            parseErrorCount: max(0, run.fileCount - parseOkCount),
            diagnosticCount: run.diagnosticCount,
            totalDurationMs: run.stageTimings.values.reduce(0, +))
    }
}
