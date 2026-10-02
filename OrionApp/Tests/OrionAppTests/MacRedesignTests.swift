import OrionCodeIntel
import XCTest

@testable import Orion

/// Docs/20: the redesign's logic, without rendering -- the window model, the sync key lookup
/// whose absence hid Docs/19 M5's switch, and the wording, sorting and grouping the views use.
@MainActor
final class MacRedesignTests: XCTestCase {
    private func window() -> RepositoryWindow {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("recents-\(UUID().uuidString).json")
        return RepositoryWindow(recents: RecentRepositoriesModel(store: RecentRepositories(fileURL: file)))
    }

    private func analyzedRepo() throws -> URL {
        let repoRoot = FileManager.default.temporaryDirectory.appendingPathComponent("MacRedesignTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: repoRoot, withIntermediateDirectories: true)
        try "def foo():\n    pass\n".write(to: repoRoot.appendingPathComponent("a.py"), atomically: true, encoding: .utf8)
        let outputDirectory = RepositorySession.outputDirectory(forRepoRoot: repoRoot)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let database = try OrionDatabase(path: outputDirectory.appendingPathComponent("orion.db").path)
        _ = try AnalysisPipeline(database: database).run(
            AnalysisInput(repoPath: repoRoot, outputDirectory: outputDirectory, resolve: false))
        return repoRoot
    }

    // MARK: - Window model

    func testTheFirstModelChangeCountIsTheBaselineAndViewingClearsTheBadge() {
        let window = window()
        window.recordModelChangeCount(50, viewing: false)
        XCTAssertEqual(window.unreadModelChanges, 0, "a repository's history isn't unread")
        window.recordModelChangeCount(53, viewing: false)
        XCTAssertEqual(window.unreadModelChanges, 3)
        window.recordModelChangeCount(53, viewing: true)
        XCTAssertEqual(window.unreadModelChanges, 0)
    }

    func testClosingARepositoryStartsTheWindowFresh() {
        let window = window()
        window.shell.destination = .ask
        window.recordModelChangeCount(5, viewing: false)
        window.closeRepository()
        XCTAssertEqual(window.session.state, .idle)
        XCTAssertEqual(window.shell.destination, .overview)
        XCTAssertNil(window.syncKey)
    }

    /// The Docs/19 M5 switch never appeared because this lookup never ran. It must find the key
    /// for an analyzed repository, even while another connection holds the database.
    func testTheSyncKeyIsFoundForAnAnalyzedRepository() async throws {
        let repoRoot = try analyzedRepo()
        let outputDirectory = RepositorySession.outputDirectory(forRepoRoot: repoRoot)
        let held = try OrionDatabase(path: outputDirectory.appendingPathComponent("orion.db").path)
        let key = await RepositoryWindow.lookUpSyncKey(outputDirectory: outputDirectory)
        XCTAssertNotNil(key)
        XCTAssertEqual(key, try IPhoneSync.libraryKey(outputDirectory: outputDirectory))
        _ = held
    }

    func testThereIsNoSyncKeyBeforeAnalysis() async throws {
        let empty = FileManager.default.temporaryDirectory.appendingPathComponent("MacRedesignTests-empty-\(UUID().uuidString)")
        let key = await RepositoryWindow.lookUpSyncKey(outputDirectory: empty)
        XCTAssertNil(key)
    }

    func testOpeningAFolderRecordsItAsRecent() {
        let window = window()
        let folder = URL(fileURLWithPath: "/tmp/does-not-exist-\(UUID().uuidString)")
        window.openFolder(folder)
        XCTAssertEqual(window.recents.entries.first?.input, folder.path)
        XCTAssertEqual(window.recents.entries.first?.displayName, folder.lastPathComponent)
    }

    func testARecentEntryReopensAsFolderOrClone() {
        let folder = RecentRepositoryEntry(input: "/Users/me/code/app", displayName: "app", lastOpened: .now)
        let github = RecentRepositoryEntry(input: "https://github.com/encode/starlette", displayName: "starlette", lastOpened: .now)
        XCTAssertEqual(RecentRepositoriesModel.input(for: folder), .localPath(URL(fileURLWithPath: "/Users/me/code/app")))
        XCTAssertEqual(RecentRepositoriesModel.input(for: github), .gitHubURL(URL(string: "https://github.com/encode/starlette")!))
    }

    // MARK: - Shell

    func testDestinationTitlesAreShortAndShortcutsAreOneToFive() {
        for destination in Destination.allCases {
            XCTAssertLessThan(destination.title.count, 15, "HIG: keep a title under 15 characters")
        }
        XCTAssertEqual(Destination.allCases.map(\.shortcut.character), ["1", "2", "3", "4", "5"])
        XCTAssertEqual(Destination.teaching.title, "Learn", "the iPhone's word")
    }

    func testSettingInspectorContentOpensTheInspectorAndClearingClosesIt() {
        let shell = AppShellState()
        let node = ArchitectureNode(id: "n", name: "Core", subtitle: nil, size: 1, confidenceTier: "high", epistemicType: "INTERPRETATION")
        shell.inspectorContent = .node(node, .structural(moduleCount: 1))
        XCTAssertTrue(shell.isInspectorPresented)
        shell.inspectorContent = nil
        XCTAssertFalse(shell.isInspectorPresented)
    }

    func testTheSyncSymbolFollowsTheState() {
        XCTAssertEqual(SyncToolbarButton.symbol(for: .off), "iphone")
        XCTAssertEqual(SyncToolbarButton.symbol(for: .pending), "iphone.and.arrow.forward")
        XCTAssertEqual(SyncToolbarButton.symbol(for: .uploaded(.now)), "iphone.badge.checkmark")
        XCTAssertEqual(SyncToolbarButton.symbol(for: .failed("x")), "iphone.badge.exclamationmark")
    }

    func testCloneAcceptsOnlyAnHTTPSRepositoryURL() {
        XCTAssertNotNil(CloneRepositorySheet.validURL("  https://github.com/encode/starlette \n"))
        XCTAssertNil(CloneRepositorySheet.validURL("http://github.com/encode/starlette"))
        XCTAssertNil(CloneRepositorySheet.validURL("https://github.com"))
        XCTAssertNil(CloneRepositorySheet.validURL("starlette"))
    }

    // MARK: - Architecture

    func testConfidenceSortsHighestFirstAndStructuralLast() {
        func node(_ tier: String?) -> ArchitectureNode {
            ArchitectureNode(id: tier ?? "none", name: "x", subtitle: nil, size: 0, confidenceTier: tier, epistemicType: "FACT")
        }
        let ranks = [node(nil), node("low"), node("high"), node("unresolved"), node("medium")]
            .sorted { $0.confidenceRank < $1.confidenceRank }
            .map(\.confidenceTier)
        XCTAssertEqual(ranks, ["high", "medium", "low", "unresolved", nil])
    }

    func testMembersAreGroupedClassesFirstWithPluralTitles() {
        func member(_ name: String, _ kind: String) -> ComponentMemberDetail {
            ComponentMemberDetail(id: name, anchor: "a.py::\(name)", name: name, kind: kind, startLine: 1, endLine: 2)
        }
        let groups = ComponentMembersList.groups([
            member("router", "variable"), member("b", "function"), member("Router", "class"), member("a", "function"),
            member("create_app", "reexport"),
        ])
        XCTAssertEqual(groups.map(\.title), ["Classes", "Functions", "Variables", "Re-exports"])
        XCTAssertEqual(groups[1].members.map(\.name), ["a", "b"])
    }

    func testRelationshipsAndOpenQuestionsReadAsWords() {
        XCTAssertEqual(ComponentDependencyRow.verb("depends_on"), "Depends on")
        XCTAssertEqual(ArchitectureLayerBar.openQuestionsTitle(1), "1 Open Question")
        XCTAssertEqual(ArchitectureLayerBar.openQuestionsTitle(4), "4 Open Questions")
        XCTAssertEqual(ArchitectureModelDiagnosticsSection.outcomeTitle("partially_verified"), "Partially Verified")
    }

    func testEvidenceSheetTitlesTheSymbolAndSubtitlesItsPlace() {
        XCTAssertEqual(EvidenceView.title("pkg/app.py::Router.add_route"), "Router.add_route")
        XCTAssertEqual(EvidenceView.title("pkg/app.py"), "app.py")
        XCTAssertEqual(
            EvidenceView.subtitle(EvidenceDetail(id: "e", anchor: "pkg/app.py::Router", startLine: 20, endLine: 50)),
            "pkg/app.py · lines 20–50")
        XCTAssertEqual(
            EvidenceView.subtitle(EvidenceDetail(id: "e", anchor: "pkg/app.py::x", startLine: 7, endLine: 7)),
            "pkg/app.py · line 7")
    }

    // MARK: - Ask, Learn, Model Changes

    func testRecordedButUnreadClaimsAreStillCounted() {
        XCTAssertEqual(AskAnswerView.claimCountText(recorded: 1, dropped: 0), "1 claim recorded")
        XCTAssertEqual(AskAnswerView.claimCountText(recorded: 3, dropped: 2), "3 claims recorded, 2 dropped")
    }

    func testConceptSearchAndOverview() {
        func row(_ id: String, _ label: String) -> TeachingConceptRow {
            TeachingConceptRow(
                id: id, label: label, kind: "component", difficultyBand: 1, centrality: 0, pMastered: 0.15,
                confidenceBand: "new", attempts: 0, lastVerdict: nil, openMisconceptions: [], plannerScore: 0)
        }
        let rows = [row("a", "Routing"), row("b", "Exception Handling")]
        XCTAssertEqual(ConceptList.filter(rows, by: "rout").map(\.id), ["a"])
        XCTAssertEqual(ConceptList.filter(rows, by: " ").map(\.id), ["a", "b"])
        let overview = TeachingOverview(total: 60, solid: 3, developing: 0, shaky: 2, new: 55, misconceptionConcepts: 1)
        XCTAssertEqual(ConceptList.overviewText(overview), "60 concepts · 3 solid · 2 shaky · 1 misconception")
    }

    func testModelChangesSelectTheFocusedRevisionElseTheNewest() {
        func entry(_ id: String) -> ModelChangeSummary {
            ModelChangeSummary(id: id, title: id, when: "now", before: "", after: "", reason: "")
        }
        let entries = [entry("r2-0"), entry("r1-0"), entry("r1-1")]
        XCTAssertEqual(ModelChangesView.initialSelection(in: entries, focusedRevisionId: "r1"), "r1-0")
        XCTAssertEqual(ModelChangesView.initialSelection(in: entries, focusedRevisionId: nil), "r2-0")
        XCTAssertEqual(ModelChangesView.initialSelection(in: entries, focusedRevisionId: "gone"), "r2-0")
    }
}
