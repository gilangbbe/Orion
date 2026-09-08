import Grape
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
                ContentUnavailableView(
                    "No architecture data yet", systemImage: "square.dashed",
                    description: Text("Analysis hasn't produced any modules to show."))
            } else if shellState.viewMode == .diagram {
                diagram(model)
            } else {
                nodeList(model)
            }
        }
    }

    /// Docs/14 §8 M8.8 item 3: with the inspector open, this banner's own column narrows a lot --
    /// without an explicit `.lineLimit`, the `Label`'s text wrapped to a second line instead of
    /// truncating, throwing off the row's vertical centering against the badge next to it (badge
    /// looked stuck at the top of a now-two-line row instead of filling the row's height evenly).
    /// `.lineLimit(1)` + `.truncationMode(.tail)` on the label and `.fixedSize()` on the badge fix
    /// both halves of that: the text truncates gracefully instead of wrapping, and the badge keeps
    /// its own compact intrinsic size instead of being squeezed by the layout pass.
    private func banner(for layer: ArchitectureLayer) -> some View {
        HStack(spacing: 8) {
            switch layer {
            case .structural(let moduleCount):
                Label(
                    "Structural view — no architecture investigation yet (\(moduleCount) modules)",
                    systemImage: "cube"
                )
                .lineLimit(1)
                .truncationMode(.tail)
                EpistemicBadge(.fact)
                    .fixedSize()
            case .semantic(_, let componentCount, let investigatedAt):
                Label(
                    "Semantic view — \(componentCount) components"
                        + (investigatedAt.map { ", investigated \($0)" } ?? ""),
                    systemImage: "sparkles"
                )
                .foregroundStyle(.blue)
                .lineLimit(1)
                .truncationMode(.tail)
                EpistemicBadge(.interpretation)
                    .fixedSize()
            }
            Spacer(minLength: 0)
        }
        .font(.callout)
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
                Text(uncertainties.first ?? "")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
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

    /// Grape's own docs are explicit that linking to a node id absent from the diagram crashes
    /// the view -- `ArchitectureModelLoader` already guarantees every edge's endpoints exist
    /// among `model.nodes` (filtered at load time, unit-tested), so this view never has to
    /// re-check that itself.
    private func diagram(_ model: ArchitectureModel) -> some View {
        ForceDirectedGraph {
            Series(model.nodes) { node in
                NodeMark(id: node.id)
                    .foregroundStyle(color(for: node))
                    .symbolSize(radius: radius(for: node))
                    .annotation(node.name, alignment: .bottom)
            }
            Series(model.edges) { edge in
                LinkMark(from: edge.sourceId, to: edge.targetId)
                    .stroke(
                        edge.confidenceTier == "high" ? Color.secondary.opacity(0.6) : Color.orange,
                        StrokeStyle(
                            lineWidth: 1.5,
                            dash: edge.confidenceTier == "high" ? [] : [4, 3])
                    )
            }
        } force: {
            // Docs/14 §8 M8.5 item 2: tuned for spacing -- the library's own defaults
            // (`manyBody(strength: -30)`, `link(originalLength: 30)`, no collision force at all)
            // are what produced the cramped, overlapping cluster this milestone exists to fix,
            // confirmed against the vendored Grape package source (`ForceDescriptor.swift`).
            // `.collide()` is new here: previously nothing stopped two nodes from overlapping
            // regardless of repulsion strength; sizing its radius from each node's own
            // `radius(for:)` (plus fixed padding) makes overlap structurally impossible rather
            // than just less likely.
            .manyBody(strength: -220)
            .link(originalLength: 90.0)
            .center()
            .collide(
                radius: .varied { (id: String) in
                    guard let node = model.nodes.first(where: { $0.id == id }) else { return 16 }
                    return radius(for: node) + 12
                })
        }
        .graphOverlay { proxy in
            Rectangle().fill(.clear).contentShape(Rectangle())
                .onTapGesture { location in
                    if let id = proxy.node(of: String.self, at: location),
                        let node = model.nodes.first(where: { $0.id == id })
                    {
                        shellState.inspectorContent = .node(node, model.layer)
                    }
                }
        }
    }

    /// Docs/14 §8 M8.5 item 2: a per-node-identity color, not confidence-tier-based (that stays
    /// visible via `ConfidenceBadge` in the inspector and in `nodeList`'s own row badge, so
    /// nothing is lost, just relocated -- a deliberate trade-off, since this diagram's node fill
    /// was previously the one place confidence was visible without opening a node). Hashed from
    /// `node.id` into a fixed palette rather than `Int.random`, so a given node is always the same
    /// color across reloads instead of reshuffling every re-render -- "randomly assigned" in the
    /// sense the palette has nothing to do with confidence, not literally nondeterministic.
    /// `String.hashValue` itself is seeded per-process (Swift's hash-flooding protection), so a
    /// small deterministic hash is used here instead, to keep the mapping stable across launches
    /// too, not just within one running session.
    private func color(for node: ArchitectureNode) -> Color {
        let palette: [Color] = [
            .blue, .green, .orange, .purple, .pink, .teal, .mint, .cyan, .brown, .indigo, .red,
            .yellow,
        ]
        return palette[Self.stableHash(node.id) % palette.count]
    }

    /// FNV-1a, chosen only for being tiny and dependency-free -- this has no correctness
    /// requirements beyond "deterministic across runs," not cryptographic ones.
    private static func stableHash(_ string: String) -> Int {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1_099_511_628_211
        }
        return Int(hash % UInt64(Int.max))
    }

    private func radius(for node: ArchitectureNode) -> CGFloat {
        node.confidenceTier == nil ? 8 : min(24, 8 + sqrt(Double(node.size)) * 3)
    }
}
