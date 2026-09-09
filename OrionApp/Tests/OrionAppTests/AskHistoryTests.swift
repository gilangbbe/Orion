import XCTest

@testable import Orion
import OrionAgent
import OrionCodeIntel

/// Docs/15_phase5_adaptive_exploration.md M6: `AskHistory` was rewritten from a pure, synchronous,
/// UI-local model (Docs/14_phase4_5_ui_ux_redesign.md §8 M4's own `AskHistoryTests`) into a real,
/// DB-backed session model -- these tests replace that file's coverage entirely, against a real
/// analyzed fixture repo (the same `AnalysisPipeline`-against-a-temp-repo pattern
/// `SemanticInvestigationRunnerTests` already established), not a mock.
final class AskHistoryTests: XCTestCase {

    private func makeAnalyzedFixtureRepo() throws -> (repoRoot: URL, outputDirectory: URL) {
        let repoRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("AskHistoryTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: repoRoot, withIntermediateDirectories: true)
        try "def foo():\n    pass\n".write(
            to: repoRoot.appendingPathComponent("a.py"), atomically: true, encoding: .utf8)

        let outputDirectory = RepositorySession.outputDirectory(forRepoRoot: repoRoot)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let database = try OrionDatabase(path: outputDirectory.appendingPathComponent("orion.db").path)
        _ = try AnalysisPipeline(database: database).run(
            AnalysisInput(repoPath: repoRoot, outputDirectory: outputDirectory, resolve: false))
        return (repoRoot, outputDirectory)
    }

    /// Ingests one real component ("Core", member `a.py::foo`) via `SemanticImporter.ingest`
    /// directly -- no `claude` stub needed, mirrors `ArchitectureModelLoaderTests`' own posture
    /// for tests that only care what happens *after* a component is already persisted.
    @discardableResult
    private func ingestOneComponent(outputDirectory: URL) throws -> String {
        let store = Store(try OrionDatabase(path: outputDirectory.appendingPathComponent("orion.db").path))
        guard let run = try store.latestRun(commitHash: nil) else {
            throw XCTSkip("expected an analyzed run")
        }
        let candidate = """
            {"schema_version": "phase2.v1",
             "components": [{"name": "Core", "description": "The one function.", "members": ["a.py::foo"]}],
             "component_relationships": [], "claims": [], "uncertainties": []}
            """
        let file = outputDirectory.appendingPathComponent("candidate-\(UUID().uuidString).json")
        try candidate.write(to: file, atomically: true, encoding: .utf8)
        let outcome = try SemanticImporter(store: store).ingest(candidateURL: file, metaURL: nil, run: run, now: "t0")
        return try XCTUnwrap(store.components(investigationId: outcome.investigation.id).first?.id)
    }

    /// Mirrors `AgentSessionTests`' own `ScriptedSession` -- a `TurnGenerating` stub so
    /// `--force-depth 1` answers without a live model load.
    private final class ScriptedSession: TurnGenerating {
        private var script: [String]
        init(_ script: [String]) { self.script = script }
        func respond(to message: String) async throws -> String {
            guard !script.isEmpty else {
                XCTFail("ScriptedSession ran out of scripted responses")
                return "{}"
            }
            return script.removeFirst()
        }
    }

    private func stubAgentSession(repoRoot: URL, outputDirectory: URL, script: [String]) -> AgentSession {
        let config = AgentSessionConfig(repoRoot: repoRoot, outputDirectory: outputDirectory, forceDepth: 1)
        return AgentSession(config: config, sessionFactory: { _ in ScriptedSession(script) })
    }

    /// Mirrors `AgentSessionTests.StubDepthFallback` -- `--force-depth` always stays in scope by
    /// design (Docs/15 §3.2), so reaching a decline in a test requires driving the real routing
    /// path with a scripted `DepthFallbackClassifying` instead.
    private struct StubDepthFallback: DepthFallbackClassifying {
        let result: DepthDecision
        func classify(_ question: String) async throws -> DepthDecision { result }
    }

    private func decliningAgentSession(repoRoot: URL, outputDirectory: URL) -> AgentSession {
        let config = AgentSessionConfig(repoRoot: repoRoot, outputDirectory: outputDirectory)
        let fallback = StubDepthFallback(
            result: DepthDecision(
                depth: 3, intent: "unclassified", confidence: .low,
                rationale: "This looks like a general knowledge question, not one about the"
                    + " analyzed repository.",
                method: .model, isInScope: false))
        return AgentSession(
            config: config, sessionFactory: { _ in ScriptedSession([]) }, depthFallback: fallback)
    }

    // MARK: refresh

    func testRefreshWithNoAnalyzedRunLeavesSessionsEmpty() async throws {
        let history = AskHistory()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        await history.refresh(outputDirectory: dir)
        XCTAssertTrue(history.sessions.isEmpty)
    }

    // MARK: createSession

    func testCreateRepositoryScopedSessionAppearsAfterRefresh() async throws {
        let (_, outputDirectory) = try makeAnalyzedFixtureRepo()
        let history = AskHistory()
        let id = try await history.createSession(
            scopeType: .repository, componentId: nil, title: "General", outputDirectory: outputDirectory)

        XCTAssertFalse(id.isEmpty)
        XCTAssertEqual(history.sessions.map(\.id), [id])
        XCTAssertNil(history.sessions.first?.componentName)
        XCTAssertEqual(history.groups(matching: "").map(\.name), ["General"])
    }

    func testComponentScopedSessionResolvesTheComponentsRealName() async throws {
        let (_, outputDirectory) = try makeAnalyzedFixtureRepo()
        let componentId = try ingestOneComponent(outputDirectory: outputDirectory)
        let history = AskHistory()
        _ = try await history.createSession(
            scopeType: .component, componentId: componentId, title: "About Core",
            outputDirectory: outputDirectory)

        XCTAssertEqual(history.sessions.first?.componentName, "Core")
        XCTAssertEqual(history.groups(matching: "").map(\.name), ["Core"])
    }

    // MARK: ask

    func testAskWithNoSessionSelectedFailsRatherThanSilentlyCreatingOne() async throws {
        let (repoRoot, outputDirectory) = try makeAnalyzedFixtureRepo()
        let history = AskHistory()
        let outcome = await history.ask("A question", repoRoot: repoRoot, outputDirectory: outputDirectory)
        guard case .failed = outcome else {
            return XCTFail("expected .failed when no session is selected, got \(outcome)")
        }
        XCTAssertTrue(history.sessions.isEmpty, "must not have silently created a session")
    }

    func testAskAppendsATurnAndUpdatesTheSessionsTurnCount() async throws {
        let (repoRoot, outputDirectory) = try makeAnalyzedFixtureRepo()
        let history = AskHistory()
        let sessionId = try await history.createSession(
            scopeType: .repository, componentId: nil, title: "General", outputDirectory: outputDirectory)
        await history.select(sessionId, outputDirectory: outputDirectory)

        // At least 20 chars -- Docs/12 M5's own `minLength: 20` schema floor (added after the
        // `claude` CLI once accepted the literal `"test"` as a schema-conformant answer) applies
        // to every locally-synthesized candidate too, this app's included.
        let answer = "foo is a no-op function that does nothing."
        let outcome = await history.ask(
            "What does foo do?", repoRoot: repoRoot, outputDirectory: outputDirectory,
            session: stubAgentSession(repoRoot: repoRoot, outputDirectory: outputDirectory, script: [answer]))

        guard case .answered(let summary) = outcome else {
            return XCTFail("expected .answered, got \(outcome)")
        }
        XCTAssertEqual(summary.answerText, answer)
        XCTAssertEqual(history.turns.count, 1)
        XCTAssertEqual(history.turns.first?.question, "What does foo do?")
        XCTAssertEqual(history.sessions.first?.turnCount, 1)
    }

    /// Reproduces a real reported bug: asking an out-of-scope question showed the decline for one
    /// frame, then it vanished. Root cause -- `AgentSession.ask` deliberately never persists a
    /// decline as a session turn (Docs/15 §4.5), but `AskHistory.ask(_:)` used to unconditionally
    /// call `refresh()` afterward, which reloads `turns` from the database and, finding no trace
    /// of the decline there, silently replaced the array without it.
    func testDeclinedQuestionStaysVisibleInTheTurnHistoryAfterItAnswers() async throws {
        let (repoRoot, outputDirectory) = try makeAnalyzedFixtureRepo()
        let history = AskHistory()
        let sessionId = try await history.createSession(
            scopeType: .repository, componentId: nil, title: "General", outputDirectory: outputDirectory)
        await history.select(sessionId, outputDirectory: outputDirectory)

        let outcome = await history.ask(
            "What's a good recipe for pasta?", repoRoot: repoRoot, outputDirectory: outputDirectory,
            session: decliningAgentSession(repoRoot: repoRoot, outputDirectory: outputDirectory))

        XCTAssertTrue(outcome.isDeclined)
        XCTAssertEqual(
            history.turns.count, 1,
            "the decline must still be showing in the turn history, not wiped out by reloading from the database")
        guard case .answered(let summary) = history.turns.first?.outcome else {
            return XCTFail("expected the declined turn's outcome to still be .answered, got \(String(describing: history.turns.first?.outcome))")
        }
        XCTAssertTrue(summary.isDeclined)
        // The decline correctly never advances the session's own persisted turn count (Docs/15
        // §4.5) -- distinct from the *local* `turns` array above, which must still show it.
        XCTAssertEqual(history.sessions.first?.turnCount, 0)
    }

    // MARK: resume-or-create (Docs/15 §5, finalized M5)

    func testResumeOrStartSessionResumesAnExistingOneRatherThanDuplicatingIt() async throws {
        let (_, outputDirectory) = try makeAnalyzedFixtureRepo()
        let history = AskHistory()
        let firstID = try await history.createSession(
            scopeType: .repository, componentId: nil, title: "General", outputDirectory: outputDirectory)
        history.selectedSessionID = nil

        let resumedID = await history.resumeOrStartSession(
            forGroupNamed: "General", componentId: nil, outputDirectory: outputDirectory)

        XCTAssertEqual(resumedID, firstID)
        XCTAssertEqual(history.sessions.count, 1, "must resume, not create a second General session")
    }

    func testResumeOrStartSessionCreatesWhenNoneExistsYet() async throws {
        let (_, outputDirectory) = try makeAnalyzedFixtureRepo()
        let history = AskHistory()
        let id = await history.resumeOrStartSession(
            forGroupNamed: "General", componentId: nil, outputDirectory: outputDirectory)
        XCTAssertNotNil(id)
        XCTAssertEqual(history.sessions.count, 1)
    }

    func testStartSessionAlwaysCreatesANewOneEvenWhenOneAlreadyExists() async throws {
        let (_, outputDirectory) = try makeAnalyzedFixtureRepo()
        let history = AskHistory()
        let firstID = try await history.createSession(
            scopeType: .repository, componentId: nil, title: "General", outputDirectory: outputDirectory)

        let secondID = await history.startSession(
            forGroupNamed: "General", componentId: nil, outputDirectory: outputDirectory)

        XCTAssertNotEqual(firstID, secondID, "the '+' affordance is a deliberate fresh start, never a resume")
        XCTAssertEqual(history.sessions.count, 2)
        XCTAssertEqual(history.selectedSessionID, secondID)
    }

    // MARK: "Ask about {name}" hand-off (Docs/15 §5/M6, was Docs/14 §8 M8.5 item 6)

    func testPendingScopeStartsNil() {
        XCTAssertNil(AskHistory().pendingScope)
    }

    func testAskAboutSetsPendingScopeWhenNoSessionExistsForThatComponentYet() async throws {
        let (_, outputDirectory) = try makeAnalyzedFixtureRepo()
        let history = AskHistory()
        await history.askAbout("Authentication", componentId: nil, outputDirectory: outputDirectory)

        XCTAssertEqual(history.pendingScope, "Authentication")
        XCTAssertNil(history.selectedSessionID, "must not create one immediately -- only the next explicit action does")
    }

    func testAskAboutResumesTheMostRecentExistingSessionForThatComponent() async throws {
        let (_, outputDirectory) = try makeAnalyzedFixtureRepo()
        let componentId = try ingestOneComponent(outputDirectory: outputDirectory)
        let history = AskHistory()
        let existingID = try await history.createSession(
            scopeType: .component, componentId: componentId, title: "About Core",
            outputDirectory: outputDirectory)

        await history.askAbout("Core", componentId: componentId, outputDirectory: outputDirectory)

        XCTAssertEqual(history.selectedSessionID, existingID)
        XCTAssertNil(history.pendingScope)
        XCTAssertEqual(history.sessions.count, 1, "must resume, not create a duplicate")
    }

    // MARK: real-UI-bug reproduction (reported live, see conversation record)

    /// Reproduces the exact live bug report: "Ask about {component}" from `ComponentDetailView`
    /// silently loses its component association once *any* question has ever been asked against
    /// the run -- `startSession`'s old componentId lookup went through
    /// `store.latestInvestigation(runId:)`, but every `AgentSession.ask` call (any depth, any
    /// session) inserts its own new `investigations` row (`SemanticImporter.ingestAnswer`), so
    /// `latestInvestigation` stops pointing at the Build-Architecture-Model investigation that
    /// actually owns the `ComponentRecord` the instant a first question is asked. The result: a
    /// session titled "About Core" silently gets `componentId: nil`, groups under "General"
    /// instead of "Core," and never receives `AgentSession.renderComponentContext` priming.
    func testAskAboutAComponentStillResolvesItAfterAnUnrelatedQuestionHasAlreadyBeenAsked() async throws {
        let (repoRoot, outputDirectory) = try makeAnalyzedFixtureRepo()
        let componentId = try ingestOneComponent(outputDirectory: outputDirectory)
        let history = AskHistory()

        // An unrelated general question, asked first -- this is what used to poison
        // `latestInvestigation(runId:)` for every component-scoped session created afterward.
        let generalID = try await history.createSession(
            scopeType: .repository, componentId: nil, title: "General", outputDirectory: outputDirectory)
        await history.select(generalID, outputDirectory: outputDirectory)
        let generalAnswer = "This is an unrelated general answer with enough characters."
        _ = await history.ask(
            "An unrelated general question?", repoRoot: repoRoot, outputDirectory: outputDirectory,
            session: stubAgentSession(repoRoot: repoRoot, outputDirectory: outputDirectory, script: [generalAnswer]))

        // The real reported flow: `ComponentDetailView`'s "Ask about Core" button hands off the
        // component's real id (it already has one, `ComponentDetail.id`) straight to `askAbout`.
        await history.askAbout("Core", componentId: componentId, outputDirectory: outputDirectory)
        let sessionId = await history.startSession(
            forGroupNamed: "Core", componentId: componentId, outputDirectory: outputDirectory)

        XCTAssertNotNil(sessionId)
        XCTAssertEqual(
            history.sessions.first(where: { $0.id == sessionId })?.componentName, "Core",
            "a session started from \"Ask about Core\" must resolve to the Core group, not General")
        XCTAssertEqual(history.groups(matching: "").map(\.name).sorted(), ["Core", "General"])
    }

    /// `askAbout` must not decide "no existing session for this component" off a stale in-memory
    /// `sessions` snapshot -- a fresh `AskHistory` (exactly what a first navigation to a
    /// component's "Ask about X" produces, racing `AskView`'s own `.task { refresh }`) must see
    /// an already-persisted session for that component and resume it, not offer to start a
    /// duplicate.
    func testAskAboutResumesAnExistingSessionEvenWhenCalledBeforeAnyRefresh() async throws {
        let (_, outputDirectory) = try makeAnalyzedFixtureRepo()
        let componentId = try ingestOneComponent(outputDirectory: outputDirectory)
        let existingID = try await history_makingFreshHistory(
            componentId: componentId, outputDirectory: outputDirectory)

        // A brand-new `AskHistory` instance, mirroring `ContentView`'s real lifetime rules only
        // loosely -- the point under test is that `askAbout` itself must not trust whatever
        // `sessions` happens to already hold; it must ground its resume-or-create decision in a
        // fresh read.
        let freshHistory = AskHistory()
        await freshHistory.askAbout("Core", componentId: componentId, outputDirectory: outputDirectory)

        XCTAssertEqual(freshHistory.selectedSessionID, existingID)
        XCTAssertNil(freshHistory.pendingScope)
        XCTAssertEqual(freshHistory.sessions.count, 1, "must resume, not create a duplicate")
    }

    private func history_makingFreshHistory(componentId: String, outputDirectory: URL) async throws -> String {
        let seeder = AskHistory()
        return try await seeder.createSession(
            scopeType: .component, componentId: componentId, title: "About Core",
            outputDirectory: outputDirectory)
    }

    // MARK: groups

    func testGroupsSortAlphabeticallyWithGeneralAlwaysLast() async throws {
        let (_, outputDirectory) = try makeAnalyzedFixtureRepo()
        let componentId = try ingestOneComponent(outputDirectory: outputDirectory)
        let history = AskHistory()
        _ = try await history.createSession(
            scopeType: .repository, componentId: nil, title: "General", outputDirectory: outputDirectory)
        _ = try await history.createSession(
            scopeType: .component, componentId: componentId, title: "About Core",
            outputDirectory: outputDirectory)

        XCTAssertEqual(history.groups(matching: "").map(\.name), ["Core", "General"])
    }

    func testGroupsFilterByCaseInsensitiveTitleSubstringMatch() async throws {
        let (_, outputDirectory) = try makeAnalyzedFixtureRepo()
        let history = AskHistory()
        _ = try await history.createSession(
            scopeType: .repository, componentId: nil, title: "General questions",
            outputDirectory: outputDirectory)

        XCTAssertEqual(history.groups(matching: "GENERAL").map(\.name), ["General"])
        XCTAssertTrue(history.groups(matching: "does not exist anywhere").isEmpty)
    }

    // MARK: rename/delete (Docs/15 §4.7, M8.5)

    func testRenameUpdatesTheSessionsTitleInTheList() async throws {
        let (_, outputDirectory) = try makeAnalyzedFixtureRepo()
        let history = AskHistory()
        let sessionId = try await history.createSession(
            scopeType: .repository, componentId: nil, title: "General", outputDirectory: outputDirectory)

        let succeeded = await history.rename(sessionId, title: "Renamed", outputDirectory: outputDirectory)

        XCTAssertTrue(succeeded)
        XCTAssertEqual(history.sessions.first(where: { $0.id == sessionId })?.title, "Renamed")
    }

    func testRenameWithBlankTitleFailsAndLeavesTheTitleUnchanged() async throws {
        let (_, outputDirectory) = try makeAnalyzedFixtureRepo()
        let history = AskHistory()
        let sessionId = try await history.createSession(
            scopeType: .repository, componentId: nil, title: "General", outputDirectory: outputDirectory)

        let succeeded = await history.rename(sessionId, title: "   ", outputDirectory: outputDirectory)

        XCTAssertFalse(succeeded)
        XCTAssertEqual(history.sessions.first(where: { $0.id == sessionId })?.title, "General")
        XCTAssertNotNil(history.loadError)
    }

    func testDeleteRemovesTheSessionFromTheList() async throws {
        let (_, outputDirectory) = try makeAnalyzedFixtureRepo()
        let history = AskHistory()
        let keepId = try await history.createSession(
            scopeType: .repository, componentId: nil, title: "Keep me", outputDirectory: outputDirectory)
        let deleteId = try await history.createSession(
            scopeType: .repository, componentId: nil, title: "Delete me", outputDirectory: outputDirectory)

        let succeeded = await history.delete(deleteId, outputDirectory: outputDirectory)

        XCTAssertTrue(succeeded)
        XCTAssertEqual(history.sessions.map(\.id), [keepId])
    }

    func testDeletingTheSelectedSessionClearsTheSelectionAndItsTurns() async throws {
        let (repoRoot, outputDirectory) = try makeAnalyzedFixtureRepo()
        let history = AskHistory()
        let sessionId = try await history.createSession(
            scopeType: .repository, componentId: nil, title: "General", outputDirectory: outputDirectory)
        await history.select(sessionId, outputDirectory: outputDirectory)
        _ = await history.ask(
            "What does foo do?", repoRoot: repoRoot, outputDirectory: outputDirectory,
            session: stubAgentSession(
                repoRoot: repoRoot, outputDirectory: outputDirectory,
                script: ["foo is a no-op function that does nothing."]))
        XCTAssertEqual(history.selectedSessionID, sessionId)
        XCTAssertFalse(history.turns.isEmpty)

        _ = await history.delete(sessionId, outputDirectory: outputDirectory)

        XCTAssertNil(history.selectedSessionID)
        XCTAssertTrue(history.turns.isEmpty)
    }

    func testDeletingAnUnselectedSessionLeavesTheCurrentSelectionAlone() async throws {
        let (_, outputDirectory) = try makeAnalyzedFixtureRepo()
        let history = AskHistory()
        let selectedId = try await history.createSession(
            scopeType: .repository, componentId: nil, title: "Selected", outputDirectory: outputDirectory)
        let otherId = try await history.createSession(
            scopeType: .repository, componentId: nil, title: "Other", outputDirectory: outputDirectory)
        await history.select(selectedId, outputDirectory: outputDirectory)

        _ = await history.delete(otherId, outputDirectory: outputDirectory)

        XCTAssertEqual(history.selectedSessionID, selectedId)
    }
}
