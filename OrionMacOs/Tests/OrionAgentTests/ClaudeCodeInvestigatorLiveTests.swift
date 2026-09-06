import XCTest
import OrionCodeIntel

@testable import OrionAgent

/// The one live end-to-end check M3's summary deliberately deferred: a real `claude` CLI
/// investigation over a real repository, fed straight into `SemanticImporter.ingestAnswer`.
/// Costs real Claude API usage and is not run in CI -- same posture as
/// `ActionLoopLiveTests`/`ModelBackedDepthClassifierLiveTests` (real model) and Phase 2's own
/// "Manual end-to-end (not CI -- costs real API/CLI usage)" (Docs/11_phase2_semantic_analysis.md).
///
/// Requires `ORION_AGENT_LIVE_CLAUDE_CLI_TEST=1` plus an already-authenticated `claude` on
/// PATH. Confirmed manually before writing this test: `claude -p "reply with the single word:
/// ok" --output-format json --model claude-sonnet-5 --max-budget-usd 0.05
/// --no-session-persistence` returns in ~2.4s for $0.048, `is_error: false` -- so a login
/// prompt or missing binary fails loudly rather than hanging this test.
///
/// Run the same way as the other live tests (`xcodebuild test` does not reliably forward env
/// vars to the test process; `xcodebuild build-for-testing` + `xcrun xctest` does):
/// ```
/// cd OrionMacOs
/// xcodebuild build-for-testing -scheme OrionCodeIntel-Package -destination 'platform=macOS' \
///   -derivedDataPath .build/xcodebuild
/// ORION_AGENT_LIVE_CLAUDE_CLI_TEST=1 xcrun xctest \
///   -XCTest OrionAgentTests.ClaudeCodeInvestigatorLiveTests/testRealClaudeCLIInvestigatesAndIngestsAgainstStarlette \
///   .build/xcodebuild/Build/Products/Debug/OrionAgentPackageTests.xctest
/// ```
final class ClaudeCodeInvestigatorLiveTests: XCTestCase {

    private var keepAlive: [TempDir] = []

    /// Duplicated from `OrionCodeIntelTests/Support/TestPaths.swift` -- test targets in this
    /// package don't share support code across targets (see this target's own `TempDir.swift`
    /// for the same precedent, applied there to a 20-line helper instead of a path locator).
    private var orionRepoRoot: URL {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<12 {
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent("Docs").path),
                FileManager.default.fileExists(atPath: dir.appendingPathComponent("OrionMacOs").path)
            {
                return dir
            }
            dir.deleteLastPathComponent()
        }
        fatalError("could not locate Orion repo root from \(#filePath)")
    }

    private var vendoredStarlette: URL {
        orionRepoRoot
            .appendingPathComponent("Agent Feasibility Study")
            .appendingPathComponent("vendor")
            .appendingPathComponent("starlette")
    }

    private func requireLiveClaudeCLI() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["ORION_AGENT_LIVE_CLAUDE_CLI_TEST"] == "1",
            "Set ORION_AGENT_LIVE_CLAUDE_CLI_TEST=1 to run this test -- it calls the real "
                + "claude CLI, costs real API usage, and is not run in CI."
        )
    }

    private func requireVendoredStarlette() throws {
        var isDir: ObjCBool = false
        let exists =
            FileManager.default.fileExists(atPath: vendoredStarlette.path, isDirectory: &isDir)
            && isDir.boolValue
        try XCTSkipUnless(
            exists, "vendored Starlette not present at \(vendoredStarlette.path) (it is gitignored)")
    }

    private func requireNpx() throws {
        let dirs =
            ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]
            + (ProcessInfo.processInfo.environment["PATH"]?.split(separator: ":").map(String.init) ?? [])
        let found = dirs.contains { FileManager.default.isExecutableFile(atPath: "\($0)/npx") }
        try XCTSkipUnless(found, "npx not available; skipping scip-python resolution")
    }

    /// A grounded, specific, publicly-answerable question about a well-known Starlette class --
    /// deliberately not the whole-repo "group everything into components" task Phase 2's own
    /// live run exercised (24 turns, $1.38, ~315s over the full repo). One question should need
    /// far fewer turns and far less budget.
    func testRealClaudeCLIInvestigatesAndIngestsAgainstStarlette() async throws {
        try requireLiveClaudeCLI()
        try requireVendoredStarlette()
        try requireNpx()

        let out = try TempDir()
        keepAlive.append(out)
        let db = try OrionDatabase(path: out.path("orion.db"))
        let analysis = try AnalysisPipeline(database: db).run(
            AnalysisInput(repoPath: vendoredStarlette, outputDirectory: out.url)
        )
        let exportDir = try XCTUnwrap(analysis.exportPath, "analysis did not produce an export directory")

        var investigator = ClaudeCodeInvestigator(repoRoot: vendoredStarlette, exportDir: exportDir)
        investigator.maxBudgetUsd = 1.00
        investigator.timeoutSeconds = 400

        let question =
            "What does Starlette's Router class do, and how does it dispatch an incoming "
            + "request to a matching route handler?"

        let start = ContinuousClock.now
        let investigation = try await investigator.investigate(question: question)
        let elapsed = start.duration(to: .now)
        let model = investigation.modelUsed ?? "?"
        let turns = investigation.numTurns.map { String($0) } ?? "?"
        let cost = investigation.totalCostUsd.map { String($0) } ?? "?"
        print("Live Claude CLI investigation: \(elapsed), model=\(model), turns=\(turns), cost=$\(cost)")

        XCTAssertFalse(
            investigation.timedOut, "investigation timed out after \(investigator.timeoutSeconds)s")
        XCTAssertFalse(
            investigation.isError,
            "claude CLI reported is_error; stderr tail: \(investigation.stderrTail)")
        let candidateData = try XCTUnwrap(
            investigation.candidateData,
            "no structured_output and no parseable JSON in result text; "
                + "stderr tail: \(investigation.stderrTail)")

        let store = Store(db)
        let run = try XCTUnwrap(store.latestRun(commitHash: nil))
        let outcome = try SemanticImporter(store: store).ingestAnswer(
            candidateData: candidateData, meta: investigation.investigationMeta,
            question: question, run: run, now: Timestamp.now()
        )
        let claimCount = outcome.consistent.claims.count
        let droppedCount = outcome.consistent.droppedClaims.count
        print("Ingested: outcome=\(outcome.investigation.outcome), claims=\(claimCount), dropped=\(droppedCount)")

        XCTAssertNotEqual(
            outcome.investigation.outcome, InvestigationOutcome.rejected.rawValue,
            "answer was rejected outright -- schema or decode failure, see printed diagnostics")
        XCTAssertFalse(
            outcome.consistent.claims.isEmpty,
            "expected at least one surviving, evidence-grounded claim for a concrete, "
                + "answerable question about a real, well-known class")
    }
}
