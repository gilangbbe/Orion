import SwiftUI

/// Docs/13_phase4_architecture_ui.md M4: the Docs/05 Stage 3 / Docs/08 "architecture overview"
/// screen. Renders `ArchitectureModel` (semantic components, or the Phase-1-only module import
/// graph) as a Grape force-directed diagram, with a banner stating which layer is showing so the
/// epistemic status of what's on screen is never ambiguous (Docs/04). Reloads whenever
/// `semanticSession` changes state, so completing a "Build Architecture Model" investigation
/// (M3) upgrades the view from structural to semantic without any other wiring.
///
/// Docs/14_phase4_5_ui_ux_redesign.md §4.4/§8 M3: tapping a node (or the Open Questions strip) now
/// sets the shared `shellState.inspectorContent` instead of this view's own `.sheet` -- the real
/// `ComponentDetailView`/`OpenQuestionsPanel` content lives in `ContentView`'s inspector now.
struct ArchitectureOverviewView: View {
    let repoRoot: URL
    let outputDirectory: URL
    let semanticSession: SemanticInvestigationSession
    let shellState: AppShellState

    @State private var model: ArchitectureModel?
    @State private var loadError: String?

    var body: some View {
        Group {
            if let loadError {
                ContentUnavailableView(
                    "Couldn't load architecture", systemImage: "exclamationmark.triangle",
                    description: Text(loadError))
            } else if let model {
                architecture(model)
            } else {
                ProgressView("Loading architecture…")
            }
        }
        .task(id: semanticSession.state) { await reload() }
    }

    private func reload() async {
        do {
            model = try await Task.detached(priority: .userInitiated) {
                try ArchitectureModelLoader.load(outputDirectory: outputDirectory)
            }.value
            loadError = nil
        } catch {
            loadError = String(describing: error)
        }
    }

    @ViewBuilder
    private func architecture(_ model: ArchitectureModel) -> some View {
        VStack(spacing: 0) {
            banner(for: model.layer)
            if !model.uncertainties.isEmpty {
                Divider()
                openQuestionsStrip(model.uncertainties)
            }
            Divider()
            if model.nodes.isEmpty {
                // A real reported bug: `ContentUnavailableView` defaults to centering in
                // whatever space it's given, which here is the *entire* rest of the window --
                // right below a thin banner, that reads as the banner's own empty backdrop
                // stretching awkwardly far down before anything else appears ("the bar...
                // protrudes downward"). Anchoring to the top keeps the empty state close to the
                // banner/divider that explains it, leaving any leftover space at the bottom
                // instead of splitting it evenly above and below the message.
                ContentUnavailableView(
                    "No architecture data yet", systemImage: "square.dashed",
                    description: Text("Analysis hasn't produced any modules to show.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .padding(.top, 48)
            } else if shellState.viewMode == .diagram {
                diagram(model)
            } else {
                nodeList(model)
            }
        }
    }

    /// The layer banner itself is shared with the iOS companion (`ArchitectureLayerBanner`,
    /// Docs/19 M4); this adds the Mac's own padding.
    private func banner(for layer: ArchitectureLayer) -> some View {
        ArchitectureLayerBanner(layer: layer)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
    }

    /// Docs/13 M8: Grape renders nodes on a `Canvas`-like surface with no confirmed VoiceOver
    /// support (its README documents tap/drag/zoom gestures, nothing about accessibility) --
    /// rather than assume it's perceivable, this gives every node a second, fully standard
    /// (and so trivially accessible) `List` representation with the exact same tap-to-explore
    /// behavior, not just labels bolted onto a canvas VoiceOver may never reach.
    ///
    /// Docs/14 §8 M8.5 item 5: name only by default -- `subtitle` used to render under every row
    /// unconditionally, duplicating what tapping through to the inspector's own "Purpose" section
    /// already shows. Dropping it here loses no information, it just stops showing it twice.
    ///
    /// Docs/14 §8 M8.8 item 1: `List(selection:)` + `.tag(node.id)`, the same real pattern
    /// `ContentView.sidebar(_:)` already uses for its own fully-clickable rows -- not a `Button`
    /// wrapping the row content. A `Button`'s hit area is its label's own laid-out content; the
    /// previous version's `Spacer()` between the name and the badge carried no content of its own,
    /// so clicking that empty stretch of the row did nothing. `List`'s native row selection makes
    /// the *entire* row (including that space) respond to a click, matching how every other list
    /// in this app already behaves.
    private func nodeList(_ model: ArchitectureModel) -> some View {
        List(selection: nodeSelection(model)) {
            ForEach(model.nodes) { node in
                HStack {
                    Text(node.name).font(.callout)
                    Spacer()
                    if let tier = node.confidenceTier {
                        ConfidenceBadge(tier: tier)
                    }
                }
                .tag(node.id)
                .accessibilityHint("Opens \(node.name)'s details and evidence")
            }
        }
        .listStyle(.inset)
    }

    private func nodeSelection(_ model: ArchitectureModel) -> Binding<String?> {
        Binding(
            get: {
                if case .node(let node, _) = shellState.inspectorContent { return node.id }
                return nil
            },
            set: { newID in
                guard let newID, let node = model.nodes.first(where: { $0.id == newID }) else {
                    return
                }
                shellState.inspectorContent = .node(node, model.layer)
            })
    }

    /// Docs/14 §8 M3: a slim, always-visible summary -- never buried behind a closed disclosure
    /// (Docs/13 M6's reasoning still holds: an honest "here's what we don't know" deserves the
    /// same visibility as the components), but no longer inlining every uncertainty's full text
    /// either. Tapping it opens the full list in the shared inspector (`OpenQuestionsPanel`),
    /// mutually exclusive with a selected node's detail.
    private func openQuestionsStrip(_ uncertainties: [String]) -> some View {
        Button {
            shellState.inspectorContent = .openQuestions(uncertainties)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "questionmark.circle")
                    .foregroundStyle(.secondary)
                Text("Open Questions (\(uncertainties.count))")
                    .font(.caption.bold())
                    .fixedSize()
//                Text(uncertainties.first ?? "")
//                    .font(.caption)
//                    .foregroundStyle(.secondary)
//                    .lineLimit(1)
//                    .truncationMode(.tail)
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// The map itself is shared with the iOS companion (`ArchitectureDiagramView`, Docs/19 M4);
    /// on the Mac, tapping a node opens it in the shared inspector.
    private func diagram(_ model: ArchitectureModel) -> some View {
        ArchitectureDiagramView(model: model) { node in
            shellState.inspectorContent = .node(node, model.layer)
        }
    }
}
