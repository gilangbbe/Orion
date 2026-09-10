import OrionAgent
import OrionCodeIntel
import SwiftUI

/// Renders `RepositorySession.state`. `.task(id:)` below is what actually drives
/// `idle -> opening -> analyzing` into `.ready`/`.failed` for real (Docs/13 M2) -- the app-level
/// wiring `AnalysisRunner` itself deliberately doesn't do on its own.
///
/// Docs/14_phase4_5_ui_ux_redesign.md §8 M1: `.ready` is now a `NavigationSplitView` shell
/// (`readyState(_:)`) instead of a single toolbar-and-sheets screen -- Ask and "Open Another
/// Repository" moved out of `body`'s own toolbar into the sidebar, since Ask is a `Destination`
/// now, not a sheet. `.idle`/`.opening`/`.analyzing`/`.failed` are untouched (Docs/14 §8 M2's job).
struct ContentView: View {
    let session: RepositorySession
    @State private var isPresentingOpenSheet = false
    @State private var progressTracker = AnalysisProgressTracker()
    @State private var semanticSession = SemanticInvestigationSession()
    @State private var isPresentingBuildModelSheet = false
    @State private var shellState = AppShellState()
    @State private var askHistory = AskHistory()
    @State private var diagnosticsSession = DiagnosticsSession()
    /// Docs/16_phase6_continuous_model_updates.md §8, M5: the sidebar's Model Changes badge --
    /// see the `.task(id: shellState.destination)` in `readyState(_:)` for how these three are
    /// kept current. `modelChangeBaselineSet` is the fix for a real bug found live: resetting
    /// `viewedModelChangeCount` to `0` on every fresh repository open made the badge show that
    /// repository's *entire historical* revision count as "unread" every single time the app was
    /// reopened, not just genuinely new activity -- on a repository with real pre-Phase-6 history
    /// (50 revisions before `--backfill` ever ran, 101 after) this read as "the sidebar always
    /// shows ~50 unread changes, even though nothing is actually new." The fix: the *first* time
    /// this session sees the repository's revision count, that count becomes the baseline (badge
    /// starts at 0); only revisions created *after* that baseline, within this same session, ever
    /// show as unread.
    @State private var modelChangeCount = 0
    @State private var viewedModelChangeCount = 0
    @State private var modelChangeBaselineSet = false

    var body: some View {
        content
            .frame(minWidth: 640, minHeight: 420)
            .sheet(isPresented: $isPresentingOpenSheet) {
                OpenRepositoryView(session: session)
            }
            .sheet(isPresented: $isPresentingBuildModelSheet) {
                if case .ready(let summary) = session.state {
                    BuildArchitectureModelSheet(
                        repoRoot: summary.repoRoot, outputDirectory: summary.outputDirectory,
                        session: semanticSession)
                }
            }
            .task(id: session.state) {
                switch session.state {
                case .opening:
                    // A fresh repository attempt -- any previous repo's semantic investigation,
                    // shell-navigation, and Ask history is no longer relevant.
                    semanticSession = SemanticInvestigationSession()
                    shellState = AppShellState()
                    askHistory = AskHistory()
                    diagnosticsSession = DiagnosticsSession()
                    modelChangeCount = 0
                    viewedModelChangeCount = 0
                    modelChangeBaselineSet = false
                case .analyzing:
                    guard let repoRoot = session.resolvedRepoRoot else { return }
                    progressTracker = AnalysisProgressTracker()
                    await AnalysisRunner.run(
                        repoRoot: repoRoot, session: session, progress: progressTracker)
                    // Docs/14 §8 M8: the completed run's stage log, captured once here rather
                    // than live during analysis -- `AnalysisProgressView`'s own disclosure already
                    // shows it live; Diagnostics is where it survives after that screen is gone.
                    diagnosticsSession.recordAnalysis(stageHistory: progressTracker.stageHistory)
                default:
                    break
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        switch session.state {
        case .idle:
            WelcomeView(session: session)
        case .opening(let input):
            ProgressView(openingLabel(for: input))
        case .analyzing:
            AnalysisProgressView(
                repoRoot: session.resolvedRepoRoot ?? URL(fileURLWithPath: "/"),
                progress: progressTracker)
        case .ready(let summary):
            readyState(summary)
        case .failed(let message):
            errorState(message)
        }
    }

    /// Docs/14 §4.1/§8 M1: the `NavigationSplitView` shell -- a sidebar of `Destination`s plus
    /// repo identity/Build-Model status, and a detail column showing whichever destination is
    /// selected, with the M3-reserved inspector attached at this level. Every destination's
    /// content is still exactly its pre-existing implementation (`ArchitectureOverviewView`,
    /// `AskView`) for now -- M1 is a structural relocation, not a per-screen redesign.
    private func readyState(_ summary: RepositorySummary) -> some View {
        NavigationSplitView {
            sidebar(summary)
        } detail: {
            // Docs/14 §8 M8.7: `HSplitView`, not `.inspector()`/`.inspectorColumnWidth` -- real
            // drag-testing (both this doc's own synthetic testing and, decisively, a real
            // trackpad) found the native inspector column's resize handle only shrinks toward
            // `min`, never grows past `ideal`, on this SDK (macOS 26.5), no matter what `max` is
            // set to. `HSplitView` wraps `NSSplitView` directly -- the same mature, real
            // AppKit-native divider-drag mechanism that already resizes `NavigationSplitView`'s
            // own sidebar column correctly (confirmed by the same testing) -- so per-pane
            // `.frame(minWidth:idealWidth:maxWidth:)` is the actual fix, not a hand-rolled
            // `DragGesture` reinventing what `NSSplitView` already does correctly.
            HSplitView {
                destinationContent(summary)
                    .frame(minWidth: 300, maxWidth: .infinity, maxHeight: .infinity)
                if shellState.inspectorContent != nil {
                    inspectorBody(summary)
                        // Docs/14 §7 Decision 1 / §8 M8.7: 308px floor (the prototype's proven
                        // default), 480px ceiling (roughly 1.5x the floor -- enough room for the
                        // M8.6 evidence-link rows and Dependencies section without a wide
                        // inspector dominating a modest window).
                        .frame(minWidth: 308, idealWidth: 308, maxWidth: 480, maxHeight: .infinity)
                        .background(.regularMaterial)
                }
            }
            .navigationTitle(shellState.destination.rawValue)
            // Docs/14 §8 M8.5 item 3: the Diagram/List toggle lives beside the destination
            // title now, not inline in `ArchitectureOverviewView`'s own banner -- meaningless
            // outside Overview, so only shown there.
            .toolbar {
                if shellState.destination == .overview {
                    ToolbarItem(placement: .primaryAction) {
                        Picker("View", selection: viewModeBinding) {
                            ForEach(ArchitectureViewMode.allCases) { mode in
                                Label(
                                    mode.rawValue,
                                    systemImage: mode == .diagram
                                        ? "point.3.connected.trianglepath.dotted" : "list.bullet"
                                )
                                .tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelStyle(.iconOnly)
                        .fixedSize()
                        .accessibilityLabel("Switch between diagram and list view")
                    }
                }
            }
            // Docs/16_phase6_continuous_model_updates.md §8, M5: refreshes the sidebar's Model
            // Changes badge count on every destination switch (cheap -- one COUNT-shaped read),
            // and marks the badge "read" the moment Model Changes is actually opened. A
            // session-local view of "unread," not persisted across relaunches -- a deliberate,
            // honestly-scoped v1 rather than a new per-repo local-JSON file
            // (`RecentRepositories`'s own pattern) just for one integer; revisit if that gap
            // proves to matter in practice.
            //
            // Real bug fix: the *first* time this fires for a freshly-opened repository, the
            // current count becomes the baseline for "unread" (`viewedModelChangeCount` starts
            // equal to it, not `0`) -- otherwise every repository's entire historical revision
            // count reads as "unread" on every single app open, confirmed live against a real
            // repository with pre-existing history (the badge showed that repository's full count
            // every time, never zero, regardless of whether anything was actually new).
            .task(id: shellState.destination) {
                let count = (try? ModelChangeLoader.revisionCount(
                    outputDirectory: summary.outputDirectory)) ?? modelChangeCount
                modelChangeCount = count
                if !modelChangeBaselineSet {
                    viewedModelChangeCount = count
                    modelChangeBaselineSet = true
                }
                if shellState.destination == .changes {
                    viewedModelChangeCount = modelChangeCount
                }
            }
        }
    }

    private var viewModeBinding: Binding<ArchitectureViewMode> {
        Binding(get: { shellState.viewMode }, set: { shellState.viewMode = $0 })
    }

    @ViewBuilder
    private func destinationContent(_ summary: RepositorySummary) -> some View {
        switch shellState.destination {
        case .overview:
            ArchitectureOverviewView(
                repoRoot: summary.repoRoot, outputDirectory: summary.outputDirectory,
                semanticSession: semanticSession, shellState: shellState)
        case .ask:
            // Docs/14 §4.6/§8 M4: the real master-detail redesign, backed by `askHistory` so it
            // survives navigating away and back (see `AskHistory`'s own doc comment for why that
            // isn't just `AskView`'s local `@State`).
            AskView(
                repoRoot: summary.repoRoot, outputDirectory: summary.outputDirectory,
                history: askHistory, diagnosticsSession: diagnosticsSession, shellState: shellState)
        case .changes:
            // Docs/16_phase6_continuous_model_updates.md §8, M5: real data now, via
            // `ModelChangeLoader` -- the backend Docs/14 §7 Decision 3 deferred (`RevisionDiffer`,
            // Docs/16 §4) now exists. `focusedRevisionId` drives the `CONTRADICTED`-claim ->
            // Model Changes cross-reference (Docs/14 §2).
            ModelChangesView(
                outputDirectory: summary.outputDirectory,
                focusedRevisionId: shellState.focusedModelChangeRevisionId)
        case .teaching:
            // Docs/14 §4.8/§8 M7: real screen, sample-backed data (Docs/14 §7 Decision 3) -- see
            // `TeachingSample`'s own doc comment for why.
            TeachingView(sample: .tokenManagerVsSessionManager)
        case .diagnostics:
            // Docs/14 §4.9/§8 M8: the real screen, last-only per §7 Decision 2 --
            // `DiagnosticsSession`'s own doc comment explains why it isn't a rolling log.
            // §8 M8.5 item 1: also carries the Repository detail relocated out of the sidebar's
            // now-removed disclosure -- `summary` is passed along for that section.
            DiagnosticsView(session: diagnosticsSession, summary: summary)
        }
    }

    /// Docs/14 §4.4/§8 M3: a selected node's detail, or the Open Questions list, never both --
    /// only `ArchitectureOverviewView` ever sets `shellState.inspectorContent`. The header row
    /// (title + close) is shared chrome here rather than each case's own -- `ComponentDetailView`
    /// no longer draws its own title now that it lives in this inspector instead of its own sheet.
    private func inspectorBody(_ summary: RepositorySummary) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(inspectorTitle).font(.headline)
                Spacer()
                Button {
                    shellState.inspectorContent = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 8)
            Divider()
            Group {
                switch shellState.inspectorContent {
                case .node(let node, let layer):
                    // Docs/14 §8 M8.5 item 4: `.id(node.id)` is the actual fix, not incidental --
                    // without it SwiftUI treats every selection here as an update to the same
                    // `ComponentDetailView` instance (this `switch` gives the case itself no new
                    // identity across two different nodes), so its `.task` never re-runs and
                    // `@State detail` keeps showing the previously selected node. Giving the view
                    // explicit per-node identity makes SwiftUI tear it down and recreate it --
                    // and every `@State` on it -- on every selection instead.
                    ComponentDetailView(
                        outputDirectory: summary.outputDirectory, repoRoot: summary.repoRoot,
                        node: node, layer: layer, shellState: shellState, askHistory: askHistory
                    )
                    .id(node.id)
                case .openQuestions(let uncertainties):
                    OpenQuestionsPanel(uncertainties: uncertainties)
                case nil:
                    EmptyView()
                }
            }
        }
    }

    private var inspectorTitle: String {
        switch shellState.inspectorContent {
        case .node(let node, _): return node.name
        case .openQuestions(let uncertainties): return "Open Questions (\(uncertainties.count))"
        case nil: return ""
        }
    }

    private func sidebar(_ summary: RepositorySummary) -> some View {
        List(selection: sidebarSelection) {
            Section {
                ForEach(Destination.primary) { destination in
                    sidebarRow(destination).tag(destination)
                }
            }
            Section("Advanced") {
                ForEach(Destination.advanced) { destination in
                    sidebarRow(destination).tag(destination)
                }
            }
        }
        .safeAreaInset(edge: .top) { sidebarHeader(summary) }
        .safeAreaInset(edge: .bottom) { sidebarFooter }
    }

    /// Docs/14 §4.7/§8 M6: Model Changes is the first destination that needs an unread-style
    /// count badge -- `sidebarBadgeCount(for:)` is the one place a future destination adds one,
    /// rather than each row growing its own ad-hoc conditional.
    private func sidebarRow(_ destination: Destination) -> some View {
        HStack {
            Label(destination.rawValue, systemImage: destination.systemImage)
            if let count = sidebarBadgeCount(for: destination) {
                Spacer()
                Text("\(count)")
                    .font(.caption2.bold())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(DesignTokens.accent)
                    .foregroundStyle(.white)
                    .clipShape(Capsule())
            }
        }
    }

    private func sidebarBadgeCount(for destination: Destination) -> Int? {
        switch destination {
        case .changes:
            let unread = modelChangeCount - viewedModelChangeCount
            return unread > 0 ? unread : nil
        default:
            return nil
        }
    }

    /// Docs/14 §8 M3: no manual inspector-clearing here anymore -- `AppShellState.destination`'s
    /// own setter does that as a side effect of the destination actually changing.
    private var sidebarSelection: Binding<Destination?> {
        Binding(
            get: { shellState.destination },
            set: { newValue in
                if let newValue { shellState.destination = newValue }
            })
    }

    /// Docs/14 §4.1: repo identity in the sidebar's top `safeAreaInset`.
    ///
    /// Docs/14 §8 M8.5 item 1: this used to be a `DisclosureGroup` wrapping the summary line --
    /// carried over unchanged from Docs/13's pre-4.5 header, per this doc's own earlier comment
    /// here. Reproduced live and confirmed real: expanding it didn't just reveal the detail
    /// underneath, it collapsed the *entire* sidebar and the detail column to a blank state
    /// (root cause not fully isolated -- candidate is a `DisclosureGroup` expanding inside a
    /// `List`'s `.safeAreaInset(edge: .top)` fighting `NavigationSplitView`'s own layout pass).
    /// Fixed by removing the disclosure entirely; the detail it used to reveal (Repository path,
    /// Languages, Resolver, the `resolver == "none"` transparency caption, parse errors,
    /// diagnostics, analysis time) moved to Diagnostics's new "Repository" section instead of
    /// disappearing -- see `DiagnosticsView.repositorySection(_:)`.
    /// Docs/14 §8 M8.8 item 2: both `Text`s now explicitly respect the sidebar's own width instead
    /// of sizing to their own intrinsic (unwrapped) content -- without `.frame(maxWidth: .infinity)`
    /// on the `VStack`, a long repository name or the stats line could demand more width than the
    /// sidebar column actually has, protruding past its right edge rather than wrapping or
    /// truncating within it. The repo name truncates (`.lineLimit(1)`, matching the pattern
    /// `AskSessionRow` rows and other single-line labels already use elsewhere in this app); the
    /// stats line wraps instead (`.fixedSize(horizontal: false, vertical: true)`, the same
    /// technique `WelcomeView`'s own subtitle already uses for exactly this "long `Text` in a
    /// constrained column" shape) since truncating counts would hide real information a developer
    /// might actually want to read in full.
    private func sidebarHeader(_ summary: RepositorySummary) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(summary.repoRoot.lastPathComponent)
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.middle)
            Text(
                "\(summary.fileCount) files · \(summary.symbolCount) symbols · \(summary.relationshipCount) relationships"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    /// Docs/14 §4.1: Build Architecture Model status (Docs/13 M3, relocated from the old
    /// `readyHeader`'s trailing half -- `.trailing` alignment there only made sense beside the
    /// identity block in a horizontal header; a vertical sidebar footer wants `.leading`, so that
    /// one alignment value changed, nothing else) plus "Open Another Repository," pinned below
    /// the destination list so both persist across every destination instead of only Overview.
    private var sidebarFooter: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider()
            semanticInvestigationSection
            Button {
                isPresentingOpenSheet = true
            } label: {
                Label("Open Another Repository…", systemImage: "folder.badge.plus")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
    }

    /// Docs/13 M3: the explicit, cost-gated "Build Architecture Model" action and its outcome --
    /// a compact summary now that the Architecture Overview (M4) actually renders the result
    /// below; `orion-index ingest-semantic`'s own CLI output reports the same counts.
    @ViewBuilder
    private var semanticInvestigationSection: some View {
        switch semanticSession.state {
        case .idle:
            Button("Build Architecture Model…") { isPresentingBuildModelSheet = true }
        case .investigating:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Investigating…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .completed(let summary):
            VStack(alignment: .leading, spacing: 2) {
                Label(
                    "\(summary.componentCount) components: \(summary.outcome)",
                    systemImage: summary.outcome == "verified" ? "checkmark.seal.fill" : "exclamationmark.seal"
                )
                .font(.caption)
                .foregroundStyle(summary.outcome == "verified" ? .green : .orange)
                if let cost = summary.totalCostUsd {
                    Text("Cost: \(cost.formatted(.currency(code: "USD")))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Button("Rebuild…") { isPresentingBuildModelSheet = true }
                    .controlSize(.small)
            }
        case .failed(let message):
            VStack(alignment: .leading, spacing: 2) {
                Label("Architecture model failed", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Button("Try Again…") { isPresentingBuildModelSheet = true }
                    .controlSize(.small)
            }
        }
    }

    private func errorState(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 40))
                .foregroundStyle(.orange)
                .accessibilityHidden(true)  // decorative; the text below already says this
            Text("Couldn't open repository")
                .font(.title2)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            // Docs/14 §8 M2: resetting alone is enough now -- `.idle` shows `WelcomeView`'s
            // embedded form directly, so there's no separate sheet left to also trigger here.
            Button("Try Again") { session.reset() }
        }
    }

    private func openingLabel(for input: RepositorySession.Input) -> String {
        switch input {
        case .localPath: return "Opening…"
        case .gitHubURL: return "Cloning…"
        }
    }
}

#Preview {
    ContentView(session: RepositorySession())
}
