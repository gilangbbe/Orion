import FoundationModels
import OrionCodeIntel
import XCTest

@testable import OrionAgent

/// Docs/19 M6: the iPhone's Ask path without a model -- `CompactContextBuilder`, `SnapshotTools`,
/// and `AgentSession`'s context-provider seam (including the one retry after a context overflow,
/// the Foundation Models skill's recovery rule).
final class CompactAskTests: XCTestCase {
    private var keepAlive: [TempDir] = []

    /// A real analyzed repository (`Router.dispatch` calls `handlers.handle`) plus a semantic layer:
    /// one component and two claims about dispatching, one of them `CONTRADICTED`.
    private func analyzed() throws -> (repoRoot: URL, outDir: URL, store: Store, run: AnalysisRunRecord) {
        let repo = try TempDir()
        keepAlive.append(repo)
        let git = GitRunner(repoPath: repo.url)
        _ = try git.run(["init", "--quiet", "-b", "main"])
        _ = try git.run(["config", "user.email", "t@e.com"])
        _ = try git.run(["config", "user.name", "T"])
        try repo.write("pkg/__init__.py", "")
        try repo.write(
            "pkg/router.py",
            "from pkg import handlers\n\nclass Router:\n    def dispatch(self, path):\n        return handlers.handle(path)\n")
        try repo.write("pkg/handlers.py", "def handle(path):\n    return path\n")
        _ = try git.run(["add", "."])
        _ = try git.run(["commit", "--quiet", "-m", "init"])
        let out = try TempDir()
        keepAlive.append(out)
        let db = try OrionDatabase(path: out.path("orion.db"))
        _ = try AnalysisPipeline(database: db).run(
            AnalysisInput(repoPath: repo.url, outputDirectory: out.url, resolve: false, export: false))
        let store = Store(db)
        let run = try XCTUnwrap(store.latestRun(commitHash: nil))

        try store.insertInvestigation(InvestigationRecord(
            id: "arch", repositoryId: run.repositoryId, commitHash: run.commitHash, runId: run.id,
            question: InvestigationRecord.architectureQuestionMarker, complexity: "high", outcome: "verified",
            createdAt: "t0"))
        try store.insertComponents([ComponentRecord(
            id: "comp", repositoryId: run.repositoryId, commitHash: run.commitHash, runId: run.id, investigationId: "arch",
            name: "Routing", description: "Matches a path to a handler and dispatches it.", architecturalRole: "core",
            confidence: 0.9, confidenceTier: "high", status: "active", epistemicType: "INTERPRETATION",
            provenance: "claude_code")])
        try store.insertClaims([
            ClaimRecord(
                id: "good", repositoryId: run.repositoryId, commitHash: run.commitHash, runId: run.id,
                investigationId: "arch", statement: "Router.dispatch hands the path to handlers.handle.",
                claimType: EpistemicType.fact.rawValue, confidence: 0.9, status: "active", createdBy: "claude_code"),
            ClaimRecord(
                id: "bad", repositoryId: run.repositoryId, commitHash: run.commitHash, runId: run.id,
                investigationId: "arch", statement: "Router dispatch caches every path forever.",
                claimType: EpistemicType.contradicted.rawValue, confidence: 0.4, status: "active", createdBy: "claude_code"),
        ])
        try store.insertEvidence([EvidenceRecord(
            id: "ev", claimId: "good", anchor: "pkg/router.py::Router.dispatch", startLine: 4, endLine: 5,
            evidenceType: "source")])
        return (repo.url, out.url, store, run)
    }

    // MARK: - Words

    func testTermsSplitIdentifiersAndDropStopwords() {
        XCTAssertEqual(
            CompactContextBuilder.terms("How does add_route work in buildMiddlewareStack?"),
            ["add_route", "add", "route", "buildmiddlewarestack", "build", "middleware", "stack"])
    }

    func testCodeWordsPickIdentifiers() {
        XCTAssertEqual(
            CompactContextBuilder.codeWords("Why does Router call add_route but not the plain function?"),
            ["Router", "add_route"], "\"Why\" is a stopword, not code")
    }

    // MARK: - Retrieval and packing

    func testCandidatesUseComponentsClaimsAndSymbolsButNeverContradictedClaims() throws {
        let f = try analyzed()
        let items = try CompactContextBuilder.candidates(store: f.store, run: f.run, question: "How does Router dispatch a path?")
        let text = items.map(\.text).joined(separator: "\n")
        XCTAssertTrue(items.contains { $0.section == .components && $0.text.hasPrefix("Routing (core)") })
        XCTAssertTrue(items.contains { $0.section == .symbols && $0.text.hasPrefix("pkg/router.py::Router") })
        XCTAssertTrue(text.contains("hands the path to handlers.handle"))
        XCTAssertTrue(text.contains("[pkg/router.py::Router.dispatch]"), "claims carry their evidence anchors")
        XCTAssertFalse(text.contains("caches every path"), "a CONTRADICTED claim must never prime the model")
    }

    func testPackAlwaysKeepsTheOverviewAndDropsTheLowestScoresFirst() {
        let items = [
            CompactContextBuilder.Item(section: .overview, text: "repo", score: .infinity),
            CompactContextBuilder.Item(section: .claims, text: String(repeating: "a", count: 40), score: 5),
            CompactContextBuilder.Item(section: .claims, text: String(repeating: "b", count: 40), score: 1),
        ]
        let packed = CompactContextBuilder.pack(items, budgetTokens: 20)
        XCTAssertTrue(packed.contains("Repository: repo"))
        XCTAssertTrue(packed.contains("aaaa"))
        XCTAssertFalse(packed.contains("bbbb"))
    }

    func testBuildTrimsUntilTheRealCountFits() async throws {
        let f = try analyzed()
        // A pessimistic counter -- one token per character -- forces the check-and-trim pass.
        let context = try await CompactContextBuilder.build(
            store: f.store, run: f.run, question: "How does Router dispatch a path?", budgetTokens: 200,
            countTokens: { $0.count })
        XCTAssertLessThanOrEqual(context.count, 200 + 120, "mandatory overview may exceed; the rest must not")
        XCTAssertTrue(context.hasPrefix("Repository:"))
    }

    // MARK: - Tools

    func testSearchClaimsSkipsContradictedClaims() throws {
        let f = try analyzed()
        let result = SearchClaimsTool(store: f.store, run: f.run).execute(arguments: ["words": "router dispatch"])
        XCTAssertTrue(result.contains("hands the path to handlers.handle"), result)
        XCTAssertTrue(result.contains("Evidence: pkg/router.py::Router.dispatch"), result)
        XCTAssertFalse(result.contains("caches every path"), result)
    }

    func testSymbolDetailsResolvesByNameAndSaysWhenItsCodeIsNotOnTheDevice() throws {
        let f = try analyzed()
        let tool = SymbolDetailsTool(store: f.store, engine: QueryEngine(f.store.db), run: f.run)
        let result = tool.execute(arguments: ["anchor": "Router"])
        XCTAssertTrue(result.hasPrefix("pkg/router.py::Router (class)"), result)
        XCTAssertTrue(result.contains("isn't on this device"), result)
        XCTAssertTrue(tool.execute(arguments: [:]).hasPrefix("Error:"))
    }

    func testThePhoneGetsFourTools() throws {
        let f = try analyzed()
        XCTAssertEqual(
            SnapshotTools.all(store: f.store, run: f.run).map(\.name),
            ["lookup_symbol", "symbol_details", "callers", "search_claims"])
    }

    // MARK: - AgentSession seams

    /// Throws the OS 27 overflow error on its first turn, then answers -- calling `lookup_symbol`
    /// each time so depth 2 has a grounded tool call.
    private final class OverflowOnceSession: ToolCallingTurnGenerating {
        let tools: [any Tool]
        let fail: Bool
        init(tools: [any Tool], fail: Bool) {
            self.tools = tools
            self.fail = fail
        }
        func respond(to message: String, toolsAllowed: Bool) async throws -> String {
            if fail {
                throw LanguageModelError.contextSizeExceeded(
                    .init(contextSize: 4096, tokenCount: 5000, debugDescription: "too big"))
            }
            let tool = try XCTUnwrap(tools.first { $0.name == "lookup_symbol" } as? AgentToolAdapter)
            _ = try await tool.call(arguments: GeneratedContent(json: #"{"query": "Router"}"#))
            return "Router lives in pkg/router.py::Router."
        }
    }

    private final class Attempts: @unchecked Sendable {
        var values: [Int] = []
        var sessions = 0
    }

    func testAContextOverflowRetriesOnceWithLessContext() async throws {
        let f = try analyzed()
        let attempts = Attempts()
        let session = AgentSession(
            config: AgentSessionConfig(repoRoot: f.repoRoot, outputDirectory: f.outDir, forceDepth: 2, toolBudget: 3),
            nativeSessionFactory: { _, tools in
                attempts.sessions += 1
                return OverflowOnceSession(tools: tools, fail: attempts.sessions == 1)
            },
            contextProvider: { request in
                attempts.values.append(request.attempt)
                XCTAssertFalse(request.tools.isEmpty, "the provider sees the tools it must budget for")
                XCTAssertTrue(request.baseInstructions.contains("investigating a codebase"))
                return "Repository: test"
            },
            toolsProvider: { store, run in SnapshotTools.all(store: store, run: run) },
            toolResultCharLimit: 40)

        let result = try await session.ask("Where is Router?")
        XCTAssertEqual(attempts.values, [0, 1])
        XCTAssertEqual(result.answerText, "Router lives in pkg/router.py::Router.")
        XCTAssertEqual(result.toolCalls.count, 1)
        XCTAssertTrue(result.toolCalls[0].result.hasSuffix("…(shortened)"), "tool results are capped")
    }

    func testWithoutAProviderAnOverflowStillPropagates() async throws {
        let f = try analyzed()
        let session = AgentSession(
            config: AgentSessionConfig(repoRoot: f.repoRoot, outputDirectory: f.outDir, forceDepth: 2),
            nativeSessionFactory: { _, tools in OverflowOnceSession(tools: tools, fail: true) })
        do {
            _ = try await session.ask("Where is Router?")
            XCTFail("expected the overflow to propagate")
        } catch LanguageModelError.contextSizeExceeded {
        }
    }

    func testTheAnswerIsReportedToThePartialAnswerCallback() async throws {
        let f = try analyzed()
        let session = AgentSession(
            config: AgentSessionConfig(repoRoot: f.repoRoot, outputDirectory: f.outDir, forceDepth: 2),
            nativeSessionFactory: { _, tools in OverflowOnceSession(tools: tools, fail: false) },
            contextProvider: { _ in "Repository: test" })
        let seen = Attempts()
        _ = try await session.ask("Where is Router?") { _ in seen.sessions += 1 }
        XCTAssertGreaterThan(seen.sessions, 0)
    }

    /// Docs/19 M6: the phone's classifier sends a third of questions to depth 3, which the phone
    /// can't delegate -- they're answered at depth 2 instead, and the trace says so.
    func testDepth3WithoutDelegationIsAnsweredAtDepth2() async throws {
        let f = try analyzed()
        var config = AgentSessionConfig(repoRoot: f.repoRoot, outputDirectory: f.outDir, forceDepth: 3, toolBudget: 3)
        config.canDelegate = false
        let session = AgentSession(
            config: config,
            nativeSessionFactory: { _, tools in OverflowOnceSession(tools: tools, fail: false) },
            contextProvider: { _ in "Repository: test" })
        let result = try await session.ask("Where is Router?")
        XCTAssertEqual(result.depthDecision.depth, 2)
        XCTAssertTrue(result.depthDecision.rationale.contains("answered at depth 2"), result.depthDecision.rationale)
        XCTAssertEqual(result.answerText, "Router lives in pkg/router.py::Router.")
        XCTAssertEqual(result.toolCalls.count, 1)
    }
}
