import AppKit
import Foundation

/// Everything one Orion window owns (Docs/20 R1). Each window opens its own repository, so File >
/// New Window can show a second one beside the first. The window's views, toolbar and the menu
/// bar's commands (through `FocusedValues.repositoryWindow`) all act through this one object.
///
/// It also holds what `ContentView` used to do inline: driving `idle -> opening -> analyzing ->
/// ready`, starting fresh per-repository state, the Model Changes badge, and the repository's
/// iPhone sync key.
@MainActor
@Observable
final class RepositoryWindow {
    let session: RepositorySession
    let recents: RecentRepositoriesModel
    let sync: IPhoneSync

    private(set) var shell = AppShellState()
    private(set) var semantic = SemanticInvestigationSession()
    private(set) var askHistory = AskHistory()
    private(set) var teaching = TeachingSession()
    private(set) var diagnostics = DiagnosticsSession()
    private(set) var progress = AnalysisProgressTracker()

    /// The open repository's CloudKit record name, once known. `nil` before a repository is ready,
    /// or when its database has no run yet. Looked up here, once per repository: the Docs/19 M5
    /// switch hung this lookup off an empty `Group`, which never ran it (Docs/20, "Why").
    private(set) var syncKey: String?

    /// Docs/16 §8 M5: the Model Changes badge. The first count this window sees is the baseline,
    /// so only revisions made while it's open count as unread -- not the repository's whole history.
    private(set) var modelChangeCount = 0
    private var viewedModelChangeCount = 0
    private var modelChangeBaselineSet = false

    var isPickingFolder = false
    var isCloning = false
    var isBuildingModel = false
    /// The toolbar's Sync to iPhone popover.
    var isShowingSyncPopover = false

    init(
        session: RepositorySession = RepositorySession(), recents: RecentRepositoriesModel,
        sync: IPhoneSync? = nil
    ) {
        self.session = session
        self.recents = recents
        self.sync = sync ?? .shared
    }

    var summary: RepositorySummary? {
        if case .ready(let summary) = session.state { summary } else { nil }
    }

    var unreadModelChanges: Int { max(0, modelChangeCount - viewedModelChangeCount) }

    var isBusy: Bool {
        switch session.state {
        case .opening, .analyzing: true
        default: false
        }
    }

    // MARK: - Opening

    func openFolder(_ url: URL) {
        recents.record(input: url.path, displayName: url.lastPathComponent)
        open(.localPath(url))
    }

    func clone(_ url: URL) {
        recents.record(input: url.absoluteString, displayName: url.lastPathComponent)
        open(.gitHubURL(url))
    }

    func reopen(_ entry: RecentRepositoryEntry) {
        recents.record(input: entry.input, displayName: entry.displayName)
        open(RecentRepositoriesModel.input(for: entry))
    }

    private func open(_ input: RepositorySession.Input) {
        Task { await session.open(input) }
    }

    /// `ContentView`'s `.task(id: session.state)`: what each state change sets in motion.
    func sessionStateChanged() async {
        switch session.state {
        case .opening:
            startFresh()
        case .analyzing:
            guard let repoRoot = session.resolvedRepoRoot else { return }
            progress = AnalysisProgressTracker()
            await AnalysisRunner.run(repoRoot: repoRoot, session: session, progress: progress)
            // Docs/14 §8 M8: the finished run's stage log, kept for Diagnostics.
            diagnostics.recordAnalysis(stageHistory: progress.stageHistory)
        case .ready(let summary):
            syncKey = await Self.lookUpSyncKey(outputDirectory: summary.outputDirectory)
            await refreshBadges()
            // Docs/19 M5: a fresh analysis or a reopened repository republishes when it syncs and
            // its knowledge changed.
            await sync.publishIfEnabled(repoRoot: summary.repoRoot, outputDirectory: summary.outputDirectory)
        default:
            break
        }
    }

    /// A new repository: nothing from the previous one carries over.
    private func startFresh() {
        semantic = SemanticInvestigationSession()
        shell = AppShellState()
        askHistory = AskHistory()
        teaching = TeachingSession()
        diagnostics = DiagnosticsSession()
        syncKey = nil
        modelChangeCount = 0
        viewedModelChangeCount = 0
        modelChangeBaselineSet = false
    }

    nonisolated static func lookUpSyncKey(outputDirectory: URL) async -> String? {
        await Task.detached(priority: .utility) {
            try? IPhoneSync.libraryKey(outputDirectory: outputDirectory)
        }.value
    }

    // MARK: - Badges

    /// On every destination switch (Docs/16 §8 M5, Docs/17 §11 M6): the Model Changes count, read
    /// as seen while Model Changes is showing, and Learn's misconception count.
    func refreshBadges() async {
        guard let summary else { return }
        let count = (try? ModelChangeLoader.revisionCount(outputDirectory: summary.outputDirectory)) ?? modelChangeCount
        recordModelChangeCount(count, viewing: shell.destination == .changes)
        await teaching.refresh(outputDirectory: summary.outputDirectory, bootstrap: false)
    }

    /// The badge's arithmetic, separate so it can be tested without a database.
    func recordModelChangeCount(_ count: Int, viewing: Bool) {
        modelChangeCount = count
        if !modelChangeBaselineSet {
            viewedModelChangeCount = count
            modelChangeBaselineSet = true
        }
        if viewing {
            viewedModelChangeCount = count
        }
    }

    // MARK: - Repository actions

    /// After Build Architecture Model completes: the phone should get the new model (Docs/19 M5).
    func architectureModelChanged() async {
        guard let summary else { return }
        syncKey = await Self.lookUpSyncKey(outputDirectory: summary.outputDirectory)
        await sync.publishIfEnabled(repoRoot: summary.repoRoot, outputDirectory: summary.outputDirectory)
    }

    var isSyncing: Bool {
        guard let syncKey else { return false }
        return sync.isEnabled(syncKey)
    }

    func setSyncing(_ on: Bool) {
        guard let syncKey, let summary else { return }
        let sync = sync
        Task { await sync.setEnabled(on, libraryKey: syncKey, repoRoot: summary.repoRoot, outputDirectory: summary.outputDirectory) }
    }

    func syncNow() {
        guard let syncKey, let summary else { return }
        let sync = sync
        Task { await sync.syncNow(libraryKey: syncKey, repoRoot: summary.repoRoot, outputDirectory: summary.outputDirectory) }
    }

    /// Repository > New Ask Session: the toolbar's New Session, from anywhere in the window.
    func newAskSession() {
        guard let summary else { return }
        shell.destination = .ask
        let history = askHistory
        Task { await history.startSession(forGroupNamed: "General", componentId: nil, outputDirectory: summary.outputDirectory) }
    }

    /// Repository > Practise Next Concept: Learn's toolbar Practise Next, from anywhere.
    func practiseNext() {
        guard let summary else { return }
        shell.destination = .teaching
        let teaching = teaching
        Task {
            await teaching.refresh(outputDirectory: summary.outputDirectory)
            await teaching.startNext(repoRoot: summary.repoRoot, outputDirectory: summary.outputDirectory)
        }
    }

    func showInFinder() {
        guard let summary else { return }
        NSWorkspace.shared.activateFileViewerSelecting([summary.repoRoot])
    }

    /// File > Close Repository: back to the welcome screen in this window.
    func closeRepository() {
        startFresh()
        session.reset()
    }
}
