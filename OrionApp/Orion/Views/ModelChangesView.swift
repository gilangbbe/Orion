import SwiftUI

/// Docs/14_phase4_5_ui_ux_redesign.md §4.7/§8 M6 / Docs/05 Stage 6: the timeline of "Understanding
/// updated" entries -- each one a subject + when, expanding to Previously / Now / Reason.
///
/// Docs/16_phase6_continuous_model_updates.md §8, M5: backed by `ModelChangeLoader` (real
/// `model_revisions`/`model_revision_entries` rows).
///
/// ## §12.4 redesign -- master/detail, not inline disclosure
///
/// Two earlier shapes were both wrong, for the same underlying reason. A `ScrollView` of
/// freestanding `DisclosureGroup` cards (the first shape) only made each card's ~12pt triangle
/// glyph interactive, and its content indent never agreed with the cards' own manual padding.
/// `List { ForEach { Section(_:isExpanded:) } }.listStyle(.sidebar)` (the §12.3 shape) was meant
/// to fix both -- but `Section(isExpanded:)` in a macOS sidebar `List` is a known AppKit-bridging
/// trouble spot (Apple Developer Forums threads 820006 / 739118 / 778432; `AskView` hit the
/// identical wall and its "Left: the session list" comment documents it), and the concrete
/// symptoms the user then reported were exactly its failure mode: the header row still didn't
/// reliably toggle (only the disclosure chevron did), and each expanded `Section`'s content was
/// clamped to a single truncated line with no way to read the rest.
///
/// The deeper point is a Human Interface Guidelines one, not a bug workaround. Apple's "Disclosure
/// controls" guidance frames a disclosure triangle as revealing *secondary information within the
/// same view* -- short, structured, glanceable. Previously / Now / Reason are multi-paragraph
/// LLM-authored prose. Long-form reading content belongs behind *navigation to a detail area*, and
/// the standard macOS shape for "a list of items, each with substantial detail" is master/detail
/// in a split view (HIG "Lists and tables"; Mail, Notes, News, System Settings, Xcode's
/// navigators). So this screen is now a list of change rows on the left and a scrollable detail
/// pane on the right -- structurally the same choice `AskView` already made, for the same reasons.
///
/// Both reported bugs are fixed by construction:
///
/// * **Hit target.** Each row is a plain `Button` filling the row's width -- the whole thing
///   selects it. There is no disclosure triangle to aim at.
/// * **Long text.** The detail pane is a `ScrollView` of freely-wrapping `MarkdownText`; nothing
///   is truncated, and every field is `.textSelection(.enabled)`.
///
/// Self-loads via `outputDirectory`, the same `@State` + `.task` pattern
/// `ArchitectureOverviewView`/`ComponentDetailView`/`AskView` already use.
struct ModelChangesView: View {
    let outputDirectory: URL
    /// Docs/16 §8, M5: set by a `CONTRADICTED`-claim's "Superseded — see Model Changes" link
    /// (`ComponentDetailView`/`AskEntryView`) -- the first row belonging to this revision is
    /// selected and scrolled to on appear. `nil` for a normal visit (the most recent row is
    /// selected then).
    let focusedRevisionId: String?

    @State private var entries: [ModelChangeSummary]?
    @State private var loadError: String?
    @State private var selectedID: String?

    var body: some View {
        Group {
            if let loadError {
                ContentUnavailableView(
                    "Couldn't load model changes", systemImage: "exclamationmark.triangle",
                    description: Text(loadError))
            } else if let entries {
                if entries.isEmpty {
                    ContentUnavailableView(
                        "No model changes yet", systemImage: "clock.arrow.circlepath",
                        description: Text("Understanding updates will show up here as they happen."))
                } else {
                    masterDetail(entries)
                }
            } else {
                ProgressView()
            }
        }
        .task { await load() }
    }

    // MARK: - Split

    /// Mirrors `AskView`'s own `HSplitView` layout and its documented reasoning: a fixed-width
    /// list pane (`minWidth == idealWidth == maxWidth`, so `NSSplitView` has no divider to drag
    /// and the pane can't be collapsed away -- this page has no toolbar sidebar-toggle to bring it
    /// back), and a flexible detail pane pinned to `maxWidth: .infinity` so its text measures
    /// against the width it's actually given and wraps, rather than against an unbounded proposal.
    private func masterDetail(_ entries: [ModelChangeSummary]) -> some View {
        HSplitView {
            changeList(entries)
                .frame(minWidth: 260, idealWidth: 260, maxWidth: 260, maxHeight: .infinity)
            detail
                .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Left: the list of changes

    /// A plain `ScrollView` + `LazyVStack` of `Button` rows, exactly like `AskView.sessionList` --
    /// selection tint is driven by this view's own `selectedID`, not by any `List`/`Section`
    /// machinery (see this file's header comment for why the native sidebar `List` was abandoned).
    private func changeList(_ entries: [ModelChangeSummary]) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(entries) { entry in
                        row(entry)
                            .id(entry.id)
                    }
                }
                .padding(8)
            }
            .onAppear { scrollToInitialSelection(entries: entries, proxy: proxy) }
        }
    }

    private func row(_ entry: ModelChangeSummary) -> some View {
        Button {
            selectedID = entry.id
        } label: {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.caption)
                    .foregroundStyle(DesignTokens.accent)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.title)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                    Text("Updated \(entry.when)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(preview(entry))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            entry.id == selectedID ? Color.accentColor.opacity(0.15) : Color.clear,
            in: RoundedRectangle(cornerRadius: 6))
    }

    /// A one-line teaser of where the model landed. Truncating *here* is fine -- it's a preview,
    /// and the full, un-clamped text is one click away in the detail pane. That's the whole point
    /// of the master/detail split.
    private func preview(_ entry: ModelChangeSummary) -> String {
        let candidate = isPresent(entry.after) ? entry.after : entry.reason
        return candidate.replacingOccurrences(of: "\n", with: " ")
    }

    // MARK: - Right: the selected change in full

    @ViewBuilder
    private var detail: some View {
        if let entry = entries?.first(where: { $0.id == selectedID }) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(entry.title)
                            .font(.title3.bold())
                        Label("Updated \(entry.when)", systemImage: "clock.arrow.circlepath")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if isPresent(entry.before) {
                        field("Previously", entry.before, tint: .secondary, ruled: false)
                    }
                    field("Now", entry.after, tint: DesignTokens.fact, ruled: true)
                    field("Reason", entry.reason, tint: .secondary, ruled: false)
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            ContentUnavailableView(
                "Select a change", systemImage: "clock.arrow.circlepath",
                description: Text("Choose an entry on the left to see what changed and why."))
        }
    }

    /// A labelled prose block. The *label* carries the color cue (`tint`); the body text stays
    /// `.primary` so it's always readable -- the pre-redesign screenshot rendered whole paragraphs
    /// in monospaced green, which a colored label + a thin leading rule communicates without
    /// fighting legibility. `MarkdownText` renders the inline `` `code` `` spans real statements
    /// carry (e.g. a `` `_TestClientTransport` `` reference) instead of showing the backticks.
    private func field(_ label: String, _ value: String, tint: Color, ruled: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(tint)
                .textCase(.uppercase)
            MarkdownText(raw: value)
                .font(.callout)
                .textSelection(.enabled)
                .padding(.leading, ruled ? 10 : 0)
                .overlay(alignment: .leading) {
                    if ruled {
                        RoundedRectangle(cornerRadius: 1)
                            .fill(tint.opacity(0.5))
                            .frame(width: 3)
                    }
                }
        }
    }

    /// The loader writes `"—"` when a field has nothing to show (an `.added` entry has no
    /// "Previously"); treat that and the empty string as absent.
    private func isPresent(_ value: String) -> Bool {
        !value.isEmpty && value != "—"
    }

    // MARK: - Load / initial selection

    private func load() async {
        do {
            let loaded = try await Task.detached(priority: .userInitiated) {
                try ModelChangeLoader.load(outputDirectory: outputDirectory)
            }.value
            entries = loaded
            selectedID = initialSelection(in: loaded)
        } catch {
            loadError = String(describing: error)
        }
    }

    /// The first row of `focusedRevisionId` when arriving from a "Superseded — see Model Changes"
    /// link; otherwise the most recent change (loader order is newest-first), so the detail pane
    /// is never blank on arrival.
    private func initialSelection(in entries: [ModelChangeSummary]) -> String? {
        if let focusedRevisionId,
            let match = entries.first(where: { $0.id.hasPrefix("\(focusedRevisionId)-") }) {
            return match.id
        }
        return entries.first?.id
    }

    private func scrollToInitialSelection(entries: [ModelChangeSummary], proxy: ScrollViewProxy) {
        guard let selectedID else { return }
        withAnimation { proxy.scrollTo(selectedID, anchor: .top) }
    }
}
