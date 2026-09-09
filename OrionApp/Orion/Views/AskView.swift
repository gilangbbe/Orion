import SwiftUI

/// Docs/14_phase4_5_ui_ux_redesign.md §4.6/§8 M4: a master-detail list, not a chat transcript --
/// Docs/15_phase5_adaptive_exploration.md §5/M6 promotes this list's unit from "one question" to
/// "one session," now that sessions are real, persisted, multi-turn conversations (Docs/15 §4)
/// rather than a UI-only tag on an otherwise independent question.
///
/// The reasoning Docs/14 gave for master-detail over a flowing transcript still holds, one level
/// up: a developer returns to a specific *session* as reference material (Docs/04 §6), scanning
/// short session titles under the component they care about instead of scrolling past every
/// unrelated session's questions. Within one selected session, though, its own turns genuinely
/// are one continuous conversation -- that's the one place a stacked, oldest-first column is the
/// right shape, and it's exactly what the detail pane now renders.
struct AskView: View {
    let repoRoot: URL
    let outputDirectory: URL
    let history: AskHistory
    let diagnosticsSession: DiagnosticsSession

    @State private var questionText = ""
    @State private var search = ""
    @State private var collapsedGroups: Set<String> = []
    @State private var isSubmitting = false
    /// Surfaces a `submit()` failure (e.g. `resumeOrStartSession` couldn't reach the database) in
    /// the Ask page itself -- the fix for a real reported bug: that failure used to be caught,
    /// stashed in `history.loadError`, and never shown anywhere, so asking a question that hit it
    /// looked exactly like nothing had happened at all (no turn, no spinner, no message).
    @State private var submitError: String?
    /// Docs/15_phase5_adaptive_exploration.md §4.7/§5, M8.5: which session a right-click's
    /// "Rename…" is currently acting on -- drives the `.sheet(item:)` below. `nil` when no rename
    /// is in progress.
    @State private var renamingSession: AskSessionRow?
    /// Same idea for "Delete" -- a destructive, hard-to-reverse action confirms first (§4.7).
    @State private var sessionPendingDelete: AskSessionRow?

    var body: some View {
        VStack(spacing: 0) {
            if history.sessions.isEmpty {
                emptyState
            } else {
                // Two real reported bugs, in order:
                // 1. The original hand-rolled `HStack(spacing: 0) { sessionList
                //    (.frame(width: 260)); Divider(); detail }` didn't reliably hold that width --
                //    the session list rendered far wider than 260pt, crowding `detail` off to the
                //    right.
                // 2. Replacing it with `NavigationSplitView` (reasoning that `ContentView`'s own
                //    top-level shell already uses it successfully) fixed that, but introduced a
                //    worse one: `NavigationSplitView`'s sidebar column is natively *collapsible* --
                //    dragging its divider far enough hides it completely, and this page has no
                //    toolbar/menu-bar sidebar-toggle affordance (it lives inside a borderless,
                //    custom-chrome floating panel, not a normal titled window) to bring it back.
                //    Once collapsed here, the session list was simply gone with no way to reopen
                //    it -- worse than the width bug it replaced.
                //
                // `HSplitView` is the actual fix, matching `ContentView.readyState(_:)`'s own
                // already-documented reasoning for its inspector column: it wraps `NSSplitView`
                // directly, a mature, real AppKit divider-drag mechanism -- and critically, unlike
                // `NavigationSplitView`, it has no built-in "collapse the whole pane" gesture of
                // its own. Giving the sidebar pane `minWidth == idealWidth == maxWidth` (this page
                // never wanted a *resizable* sidebar, just a correctly-held 260pt one) means
                // `NSSplitView` structurally cannot move that divider at all -- nothing to drag
                // away, nothing to lose.
                HSplitView {
                    sessionList
                        .frame(minWidth: 260, idealWidth: 260, maxWidth: 260, maxHeight: .infinity)
                    // A second real reported bug fixed here at the same time: `detail`'s own text
                    // (in particular a long `MarkdownText` paragraph) rendered past the visible
                    // right edge instead of wrapping, once the sidebar's own width stopped
                    // fluctuating -- `MarkdownText`'s content `VStack` (below) had nothing pinning
                    // it to the space `HSplitView` actually gives this pane, so `Text` measured
                    // itself against an effectively unbounded proposed width instead. An explicit
                    // `maxWidth: .infinity` here, mirroring `ContentView.readyState(_:)`'s own
                    // identical `destinationContent(summary).frame(minWidth: 300, maxWidth:
                    // .infinity, maxHeight: .infinity)` for its own `HSplitView` content pane, is
                    // the other half of that fix (`MarkdownText`'s own frame is the first half).
                    detail
                        .frame(minWidth: 300, maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            Divider()
            if let submitError {
                errorBanner(submitError)
            } else if let scope = history.pendingScope {
                scopeChip(scope)
            }
            inputBar
        }
        .task { await history.refresh(outputDirectory: outputDirectory) }
        .sheet(item: $renamingSession) { session in
            RenameSessionSheet(session: session) { newTitle in
                Task { await history.rename(session.id, title: newTitle, outputDirectory: outputDirectory) }
            }
        }
        // Docs/15 §4.7: a destructive, hard-to-reverse action confirms first, naming the session
        // and what specifically survives it (the underlying investigations, not the session
        // itself) -- not a bare, unconfirmed "Delete" button.
        .alert(
            "Delete “\(sessionPendingDelete?.title ?? "")”?",
            isPresented: Binding(
                get: { sessionPendingDelete != nil },
                set: { isPresented in if !isPresented { sessionPendingDelete = nil } }),
            presenting: sessionPendingDelete
        ) { session in
            Button("Delete", role: .destructive) {
                Task { await history.delete(session.id, outputDirectory: outputDirectory) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { session in
            Text(
                "This removes the session and its \(session.turnCount) turn"
                    + "\(session.turnCount == 1 ? "" : "s"). The underlying investigation history is kept."
            )
        }
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle")
                .font(.caption2)
            Text(message)
                .font(.caption)
                .lineLimit(2)
            Spacer()
            Button {
                submitError = nil
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .foregroundStyle(.orange)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.orange.opacity(0.12))
        .clipShape(Capsule())
        .padding(.horizontal, 12)
        .padding(.top, 8)
    }

    /// Docs/14 §8 M8.5 item 6's reasoning is unchanged: makes the pending scope a visible,
    /// deliberate state. The × now clears back to "General" rather than to "no scope at all" --
    /// Docs/15 §5: every question belongs to some session, there is no session-less question any
    /// more, so "ask a general question instead" means "the next session created is General," not
    /// "skip the session concept entirely."
    private func scopeChip(_ scope: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.caption2)
            Text("New session about \(scope)")
                .font(.caption)
            Button {
                history.clearPendingScope()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Ask a general question instead")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(DesignTokens.accent.opacity(0.12))
        .clipShape(Capsule())
        .padding(.horizontal, 12)
        .padding(.top, 8)
    }

    /// Docs/15 §5: a `pendingScope` set here (e.g. straight off `ComponentDetailView`'s "Ask
    /// about X," the very first thing that's ever asked in a fresh repository) must say so --
    /// this used to always show the generic "Ask a question about this repository" regardless,
    /// leaving the small scope chip below as the only clue a component-scoped session was about
    /// to be started, easy to miss and easy to mistake for the page having lost that context.
    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            if let scope = history.pendingScope {
                Text("Ask your first question about \(scope) below")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Text("Ask a question about this repository")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Left: the session list
    //
    // A real reported bug: `List { ForEach(groups) { Section(isExpanded:) { ... } header: { ... } } }`
    // with `.listStyle(.sidebar)` rendered a corrupted layout the first time this page appeared
    // (from either entry point -- the sidebar or a component's "Ask about X" hand-off), because
    // `sessions` populates asynchronously (`.task { history.refresh(...) }`) well after the List's
    // first layout pass. `Section(isExpanded:)` inside a macOS sidebar `List` is a documented
    // AppKit-bridging trouble spot independent of anything this file does -- the Apple Developer
    // Forums report the identical failure shape (a `Section`/`DisclosureGroup` in a `List`
    // rendering incorrectly, or animating inconsistently, specifically when its row count changes
    // after the List has already appeared): see
    // https://developer.apple.com/forums/thread/820006 ,
    // https://developer.apple.com/forums/thread/739118 , and
    // https://developer.apple.com/forums/thread/778432 . Rather than chase a still-open platform
    // bug, this uses the pattern those threads converge on for a *custom-row* grouped list like
    // this one (we already forgo every native `List` affordance -- selection, reordering -- in
    // favor of plain `Button` rows and manual tint, so `List` was never buying anything here): a
    // plain `ScrollView` + `LazyVStack`, with each group's collapse state and each row's selection
    // tint driven entirely by this view's own state, never by List/Section's own machinery.
    private var sessionList: some View {
        VStack(spacing: 0) {
            TextField("Search your sessions…", text: $search)
                .textFieldStyle(.roundedBorder)
                .padding(10)
            let groups = history.groups(matching: search)
            if groups.isEmpty {
                Text("No sessions match.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(groups) { group in
                            groupHeader(group)
                            if !collapsedGroups.contains(group.name) {
                                ForEach(group.sessions) { session in
                                    sessionRow(session)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 8)
                }
            }
        }
    }

    private func groupHeader(_ group: AskHistory.Group) -> some View {
        let isExpanded = !collapsedGroups.contains(group.name)
        return HStack(spacing: 4) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    if isExpanded {
                        collapsedGroups.insert(group.name)
                    } else {
                        collapsedGroups.remove(group.name)
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.right")
                        .font(.caption2.bold())
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    Text(group.name)
                        .font(.caption.bold())
                }
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Spacer()
            Button {
                Task {
                    await history.startSession(
                        forGroupNamed: group.name, componentId: group.componentId, outputDirectory: outputDirectory)
                }
            } label: {
                Image(systemName: "plus.circle")
            }
            .buttonStyle(.plain)
            .help(group.name == "General" ? "New general session" : "New session about \(group.name)")
        }
        .padding(.top, 10)
        .padding(.bottom, 4)
    }

    private func sessionRow(_ session: AskSessionRow) -> some View {
        Button {
            Task { await history.select(session.id, outputDirectory: outputDirectory) }
        } label: {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "bubble.left.and.bubble.right")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.title)
                        .font(.callout)
                        .lineLimit(2)
                        .foregroundStyle(.primary)
                    Text(
                        "\(session.turnCount) turn\(session.turnCount == 1 ? "" : "s") · "
                            + session.lastActiveAt.formatted(.relative(presentation: .named))
                    )
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            session.id == history.selectedSessionID ? Color.accentColor.opacity(0.15) : Color.clear,
            in: RoundedRectangle(cornerRadius: 5))
        // Docs/15 §4.7/§5, M8.5: the native macOS affordance for "act on this specific row,"
        // rather than a bespoke button competing for space in an already-compact 260pt row.
        .contextMenu {
            Button("Rename…") { renamingSession = session }
            Button("Delete", role: .destructive) { sessionPendingDelete = session }
        }
    }

    // MARK: - Right: the selected session's turn history

    @ViewBuilder
    private var detail: some View {
        if let selected = history.sessions.first(where: { $0.id == history.selectedSessionID }) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        Text(selected.title)
                            .font(.title3.bold())
                        if history.turns.isEmpty {
                            Text("No turns yet in this session -- ask your first question below.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                        ForEach(history.turns) { turn in
                            AskEntryView(
                                repoRoot: repoRoot, question: turn.question, outcome: turn.outcome
                            )
                            .id(turn.id)
                            if turn.id != history.turns.last?.id {
                                Divider()
                            }
                        }
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                // Keeps a freshly-submitted turn in view without the developer having to scroll
                // to it themselves -- the one place this redesign's own "stacked, oldest-first
                // column" needs to behave like a live conversation rather than a static list.
                .onChange(of: history.turns.last?.id) { _, newValue in
                    guard let newValue else { return }
                    withAnimation { proxy.scrollTo(newValue, anchor: .bottom) }
                }
            }
        } else if let scope = history.pendingScope {
            // The exact real-UI report this fixes: "Ask about {component}" landed here with no
            // indication a new session about that component was actually queued -- the generic
            // "Select a session" copy below is indistinguishable from having lost that context
            // entirely, and the scope chip alone (small, below the divider) was too easy to miss.
            ContentUnavailableView(
                "Starting a new session about \(scope)", systemImage: "bubble.left.and.bubble.right",
                description: Text("Ask your first question below to create it."))
        } else {
            ContentUnavailableView(
                "Select a session", systemImage: "bubble.left.and.bubble.right",
                description: Text("Choose a session on the left, or start a new one."))
        }
    }

    // MARK: - Bottom: asking a new question

    private var inputBar: some View {
        HStack(spacing: 8) {
            TextField(inputPlaceholder, text: $questionText)
                .textFieldStyle(.roundedBorder)
                .onSubmit(submit)
                .disabled(isSubmitting)
            Button("Ask", action: submit)
                .disabled(isSubmitting || questionText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(12)
    }

    private var inputPlaceholder: String {
        if let selected = history.sessions.first(where: { $0.id == history.selectedSessionID }) {
            return "Ask a follow-up in \"\(selected.title)\"…"
        }
        return "Ask a new question about this repository…"
    }

    /// Docs/15_phase5_adaptive_exploration.md §4.5/§5: every question belongs to a session now.
    /// When nothing is selected, resolves (resumes or creates, per `pendingScope` or "General")
    /// the session this question goes to *before* asking it -- mirrors `askAbout(_:)`'s own
    /// resume-or-create decision for the implicit "just start typing" path, not a second one.
    ///
    /// A real reported bug fixed here: `resumeOrStartSession` failing (e.g. no analyzed run, or a
    /// database error) used to be swallowed silently -- `questionText` was already cleared, no
    /// turn was ever appended (there was no session to append it to), and the only trace was
    /// `history.loadError`, which nothing displayed. From the developer's chair that looked
    /// identical to the button doing nothing at all. Now: the typed question is restored to the
    /// field instead of lost, and `submitError` surfaces the real reason in the page itself.
    private func submit() {
        let question = questionText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !isSubmitting else { return }
        submitError = nil
        questionText = ""
        isSubmitting = true
        Task {
            defer { isSubmitting = false }
            if history.selectedSessionID == nil {
                let groupName = history.pendingScope ?? "General"
                guard
                    await history.resumeOrStartSession(
                        forGroupNamed: groupName, componentId: history.pendingComponentId,
                        outputDirectory: outputDirectory) != nil
                else {
                    let reason = history.loadError ?? "Couldn't start a session."
                    submitError = "Couldn't ask that question: \(reason)"
                    questionText = question
                    diagnosticsSession.recordAsk(question: question, outcome: .failed(reason))
                    return
                }
            }
            let outcome = await history.ask(question, repoRoot: repoRoot, outputDirectory: outputDirectory)
            diagnosticsSession.recordAsk(question: question, outcome: outcome)
        }
    }
}

/// Unchanged content from before this redesign -- outcome label (including the Docs/12 Risk #5
/// "Not independently checked" treatment for ungrounded depth-1 answers, and
/// Docs/15_phase5_adaptive_exploration.md §7's declined treatment), the answer text, claims with
/// clickable evidence, and routing detail behind "Explain." Only its container changed: one turn
/// stacked among a session's others, not the sole content of the detail pane.
struct AskEntryView: View {
    let repoRoot: URL
    let question: String
    let outcome: AskOutcome?
    @State private var showExplain = false
    @State private var selectedEvidence: EvidenceDetail?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(question).font(.title3.bold())
            switch outcome {
            case nil:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(
                        "Thinking… (the first local-model question can take a few minutes to "
                            + "download real model weights)"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.orange)
            case .answered(let summary):
                answeredView(summary)
            }
        }
        .sheet(item: $selectedEvidence) { evidence in
            EvidenceView(repoRoot: repoRoot, evidence: evidence)
        }
    }

    @ViewBuilder
    private func answeredView(_ summary: AskResultSummary) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            outcomeLabel(summary)
            MarkdownText(raw: summary.answerText)
            if !summary.isDeclined {
                if !summary.claims.isEmpty {
                    claimsSection(summary.claims)
                } else if summary.claimCount > 0 || summary.droppedClaimCount > 0 {
                    // Claims were recorded but couldn't be read back (best-effort in AskRunner) --
                    // still say so, rather than silently showing nothing.
                    Text(
                        "\(summary.claimCount) claim(s) recorded"
                            + (summary.droppedClaimCount > 0
                                ? ", \(summary.droppedClaimCount) dropped" : "")
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                DisclosureGroup("Explain", isExpanded: $showExplain) {
                    explainDetail(summary)
                }
                .font(.caption)
            }
        }
    }

    /// Docs/13 M7's own ask -- "evidence links (reusing the same Evidence view as M5)" -- each
    /// claim's evidence anchors are real, clickable, and open the identical `EvidenceView` a
    /// component's members do.
    private func claimsSection(_ claims: [AskClaimSummary]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(claims) { claim in
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        EpistemicBadge(rawValue: claim.claimType)
                        ConfidenceBadge(tier: claim.confidence)
                    }
                    MarkdownText(raw: claim.statement).font(.callout)
                    if !claim.evidence.isEmpty {
                        // Docs/14 §8 M8.6: one evidence link per line -- see
                        // `ComponentDetailView.claimsList`'s identical fix for the full reasoning;
                        // an `HStack` here squeezed each anchor into its own narrow wrapped
                        // column instead of using the row's full width.
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(claim.evidence) { evidence in
                                Button {
                                    selectedEvidence = evidence
                                } label: {
                                    Text(evidence.anchor)
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.blue)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
        }
        .padding(.top, 2)
    }

    /// Docs/12 Risk #5's fix, actually applied at the UX layer here: a depth-1 answer that
    /// asserted nothing is never shown with the same green-checkmark weight a grounded
    /// depth-2/3 `verified` answer gets. Docs/15_phase5_adaptive_exploration.md §7: a guardrail
    /// decline gets its own neutral treatment, checked first -- it is a correct, complete result,
    /// never the orange "partial" warning nor the green verified seal, since neither of those
    /// mean anything for a question that was never actually investigated.
    @ViewBuilder
    private func outcomeLabel(_ summary: AskResultSummary) -> some View {
        if summary.isDeclined {
            Label("Outside this repository's scope", systemImage: "arrow.turn.up.left")
                .font(.caption.bold())
                .foregroundStyle(.secondary)
        } else if summary.isUngroundedVerified {
            Label("Not independently checked", systemImage: "questionmark.circle")
                .font(.caption.bold())
                .foregroundStyle(.orange)
        } else if summary.partial {
            // Docs/13 M8: name the real outcome (rejected/incomplete/unverified/
            // partially_verified) rather than a single generic "Partial" -- Docs/06 §7's
            // failure-transparency rule applies to *which* failure, not just that one happened.
            Label(
                "Partial — \(summary.outcome.replacingOccurrences(of: "_", with: " "))",
                systemImage: "exclamationmark.circle"
            )
            .font(.caption.bold())
            .foregroundStyle(.orange)
        } else {
            Label(
                summary.outcome.replacingOccurrences(of: "_", with: " ").capitalized,
                systemImage: "checkmark.seal.fill"
            )
            .font(.caption.bold())
            .foregroundStyle(.green)
        }
    }

    private func explainDetail(_ summary: AskResultSummary) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Depth \(summary.depth) · \(summary.routingMethod) · confidence: \(summary.routingConfidence)")
                .foregroundStyle(.secondary)
            MarkdownText(raw: summary.rationale)
                .foregroundStyle(.secondary)
            if !summary.toolCalls.isEmpty {
                Divider()
                ForEach(summary.toolCalls) { call in
                    Text("[\(call.turnIndex)] \(call.toolName)(\(call.arguments)) → \(call.result)")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.top, 4)
    }
}

/// Docs/15_phase5_adaptive_exploration.md §4.7/§5, M8.5: a focused rename prompt rather than
/// inline-edit-in-place -- `sessionRow` is a custom `Button`, not a native `List` row with its
/// own double-click-to-rename support, so a small, explicit form is the simplest primitive that
/// actually works here, not a re-implementation of that native behavior.
private struct RenameSessionSheet: View {
    let session: AskSessionRow
    let onSave: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var title: String

    init(session: AskSessionRow, onSave: @escaping (String) -> Void) {
        self.session = session
        self.onSave = onSave
        _title = State(initialValue: session.title)
    }

    private var trimmedTitle: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Rename session")
                .font(.headline)
            TextField("Title", text: $title)
                .textFieldStyle(.roundedBorder)
                .onSubmit(save)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmedTitle.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 320)
    }

    private func save() {
        guard !trimmedTitle.isEmpty else { return }
        onSave(trimmedTitle)
        dismiss()
    }
}
