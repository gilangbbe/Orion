import XCTest

@testable import Orion
import OrionCodeIntel

/// Runs the real `OrionCodeIntel.AnalysisPipeline` against a tiny fixture repo -- `resolve:
/// false` keeps it fast and network-free (no `npx`/`scip-python`), matching why `orion-index`
/// itself has a `--no-resolve` flag; SCIP resolution is already extensively covered by
/// `OrionCodeIntelTests`, so this test's only job is `AnalysisRunner`'s own wiring: does progress
/// actually get reported, and does the session actually reach `.ready` with real counts.
final class AnalysisRunnerTests: XCTestCase {
    private func makeTempRepo() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AnalysisRunnerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "def foo():\n    pass\n".write(
            to: root.appendingPathComponent("a.py"), atomically: true, encoding: .utf8)
        return root
    }

    func testRunAnalyzesARealRepoAndReachesReadyWithRealCounts() async throws {
        let repoRoot = try makeTempRepo()
        let session = RepositorySession()
        let progress = AnalysisProgressTracker()

        await AnalysisRunner.run(
            repoRoot: repoRoot, session: session, progress: progress, resolve: false)

        guard case .ready(let summary) = session.state else {
            return XCTFail("expected .ready, got \(session.state)")
        }
        XCTAssertEqual(summary.fileCount, 1)
        XCTAssertGreaterThan(summary.symbolCount, 0)  // at least `foo` itself
        XCTAssertEqual(summary.resolver, "none")  // resolve: false -> no SCIP attempted
        XCTAssertEqual(summary.languages, ["python"])
        XCTAssertEqual(
            summary.outputDirectory, RepositorySession.outputDirectory(forRepoRoot: repoRoot))
    }

    func testRunReportsProgressForEveryStageThatActuallyRan() async throws {
        let repoRoot = try makeTempRepo()
        let session = RepositorySession()
        let progress = AnalysisProgressTracker()

        await AnalysisRunner.run(
            repoRoot: repoRoot, session: session, progress: progress, resolve: false)

        // `.relationships` doesn't fire under `resolve: false` (Docs/13 M2: no SCIP-based
        // relationship building ran), but every other stage should have.
        let reportedStages = Set(progress.stageHistory.map(\.stage))
        XCTAssertEqual(
            reportedStages,
            Set(PipelineStageID.allCases.filter { $0 != .relationships }))
        XCTAssertEqual(progress.currentStage, .buildingArchitecture)  // .assembly is last
    }

    /// Regression test for a real bug: Phase 1's file/symbol/relationship ids are
    /// content-addressed per `(repository, commit)`, not per-run. Closing and reopening the
    /// same, unchanged repository used to re-run `AnalysisPipeline` unconditionally and crash
    /// with a raw SQLite `UNIQUE constraint failed: files.id` on the second `analyze`. It must
    /// now detect the existing succeeded run for the current commit and reuse it.
    func testReopeningAnAlreadyAnalyzedRepoReusesTheExistingRunInsteadOfFailing() async throws {
        let repoRoot = try makeTempRepo()
        let firstSession = RepositorySession()
        await AnalysisRunner.run(
            repoRoot: repoRoot, session: firstSession, progress: AnalysisProgressTracker(),
            resolve: false)
        guard case .ready(let firstSummary) = firstSession.state else {
            return XCTFail("expected first run to reach .ready, got \(firstSession.state)")
        }

        let secondSession = RepositorySession()
        await AnalysisRunner.run(
            repoRoot: repoRoot, session: secondSession, progress: AnalysisProgressTracker(),
            resolve: false)

        guard case .ready(let secondSummary) = secondSession.state else {
            return XCTFail(
                "expected second run to reach .ready (reused), got \(secondSession.state)")
        }
        XCTAssertEqual(secondSummary.fileCount, firstSummary.fileCount)
        XCTAssertEqual(secondSummary.symbolCount, firstSummary.symbolCount)
        XCTAssertEqual(secondSummary.relationshipCount, firstSummary.relationshipCount)
        XCTAssertEqual(secondSummary.resolver, firstSummary.resolver)
        XCTAssertEqual(secondSummary.languages, firstSummary.languages)
    }

    func testReopeningAThirdTimeStillReusesRatherThanAccumulatingRuns() async throws {
        // Guards against a fix that only tolerates exactly one re-open (e.g. by deleting and
        // recreating the DB once) rather than genuinely being idempotent.
        let repoRoot = try makeTempRepo()
        for _ in 0..<3 {
            let session = RepositorySession()
            await AnalysisRunner.run(
                repoRoot: repoRoot, session: session, progress: AnalysisProgressTracker(),
                resolve: false)
            guard case .ready = session.state else {
                return XCTFail("expected .ready on every reopen, got \(session.state)")
            }
        }
    }

    func testRunOnUnusableRepoRootFails() async throws {
        // A regular file, not a directory -- `AnalysisRunner` can't even create `<repoRoot>/.orion`
        // inside it, so this fails before `AnalysisPipeline` gets a chance to validate anything
        // itself. (A merely-*missing* path isn't a valid failure fixture here:
        // `FileManager.createDirectory(withIntermediateDirectories: true)` for `<path>/.orion`
        // creates `<path>` itself as a side effect, matching `orion-index analyze`'s own
        // `AnalyzeCommand` -- Docs/13 M1's own validation in `RepositorySession.open(_:)` is what
        // actually catches a missing path before `AnalysisRunner` is ever reached.)
        let fileNotDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AnalysisRunnerTests-file-\(UUID().uuidString)")
        try Data("not a directory".utf8).write(to: fileNotDirectory)
        let session = RepositorySession()
        let progress = AnalysisProgressTracker()

        await AnalysisRunner.run(
            repoRoot: fileNotDirectory, session: session, progress: progress, resolve: false)

        guard case .failed = session.state else {
            return XCTFail("expected .failed, got \(session.state)")
        }
    }
}
