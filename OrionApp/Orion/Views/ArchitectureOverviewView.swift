import Grape
import SwiftUI

/// Docs/13_phase4_architecture_ui.md M4: the Docs/05 Stage 3 / Docs/08 "architecture overview"
/// screen. Renders `ArchitectureModel` (semantic components, or the Phase-1-only module import
/// graph) as a Grape force-directed diagram, with a banner stating which layer is showing so the
/// epistemic status of what's on screen is never ambiguous (Docs/04). Reloads whenever
/// `semanticSession` changes state, so completing a "Build Architecture Model" investigation
/// (M3) upgrades the view from structural to semantic without any other wiring. Tapping a node
/// opens the real Component Exploration (`ComponentDetailView`, M5).
struct ArchitectureOverviewView: View {
    private enum ViewMode: String, CaseIterable, Identifiable {
        case diagram = "Diagram"
        case list = "List"
        var id: String { rawValue }
    }

    let repoRoot: URL
    let outputDirectory: URL
    let semanticSession: SemanticInvestigationSession

    @State private var model: ArchitectureModel?
    @State private var loadError: String?
    @State private var selectedNode: ArchitectureNode?
    /// Docs/13 M8: Grape renders nodes on a `Canvas`-like surface with no confirmed VoiceOver
    /// support (its README documents tap/drag/zoom gestures, nothing about accessibility) --
    /// rather than assume it's perceivable, this gives every node a second, fully standard
    /// (and so trivially accessible) `List` representation with the exact same tap-to-explore
    /// behavior, not just labels bolted onto a canvas VoiceOver may never reach.
    @State private var viewMode: ViewMode = .diagram

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
                openQuestions(model.uncertainties)
            }
            Divider()
            if model.nodes.isEmpty {
                ContentUnavailableView(
                    "No architecture data yet", systemImage: "square.dashed",
                    description: Text("Analysis hasn't produced any modules to show."))
            } else if viewMode == .diagram {
                diagram(model)
            } else {
                nodeList(model)
            }
        }
        .sheet(item: $selectedNode) { node in
            ComponentDetailView(
                outputDirectory: outputDirectory, repoRoot: repoRoot, node: node, layer: model.layer)
        }
    }

    private func banner(for layer: ArchitectureLayer) -> some View {
        HStack {
            switch layer {
            case .structural(let moduleCount):
                Label(
                    "Structural view — no architecture investigation yet (\(moduleCount) modules)",
                    systemImage: "cube")
                EpistemicBadge(.fact)
            case .semantic(_, let componentCount, let investigatedAt):
                Label(
                    "Semantic view — \(componentCount) components"
                        + (investigatedAt.map { ", investigated \($0)" } ?? ""),
                    systemImage: "sparkles"
                )
                .foregroundStyle(.blue)
                EpistemicBadge(.interpretation)
            }
            Spacer()
            Picker("View", selection: $viewMode) {
                ForEach(ViewMode.allCases) { mode in
                    Label(mode.rawValue, systemImage: mode == .diagram ? "point.3.connected.trianglepath.dotted" : "list.bullet")
                        .tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelStyle(.iconOnly)
            .fixedSize()
            .accessibilityLabel("Switch between diagram and list view")
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// The accessible alternative to `diagram(_:)` -- a standard `List`, so every node is a real,
    /// VoiceOver-navigable row with the identical tap-to-explore destination, not a second-class
    /// fallback.
    private func nodeList(_ model: ArchitectureModel) -> some View {
        List(model.nodes) { node in
            Button {
                selectedNode = node
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(node.name).font(.callout)
                        if let subtitle = node.subtitle {
                            Text(subtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    Spacer()
                    if let tier = node.confidenceTier {
                        ConfidenceBadge(tier: tier)
                    }
                }
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens \(node.name)'s details and evidence")
        }
        .listStyle(.inset)
    }

    /// Docs/13 M6: an investigation's `uncertainties[]` surface here, visible by default (not
    /// behind a closed disclosure) -- an honest "here's what we don't know" is as much a part of
    /// the architecture picture as the components themselves (Docs/04).
    private func openQuestions(_ uncertainties: [String]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Open questions (\(uncertainties.count))", systemImage: "questionmark.circle")
                .font(.caption.bold())
                .foregroundStyle(.secondary)
            ForEach(uncertainties, id: \.self) { statement in
                HStack(alignment: .top, spacing: 6) {
                    EpistemicBadge(.unknown)
                    Text(statement).font(.caption)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
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
            .manyBody()
            .link()
            .center()
        }
        .graphOverlay { proxy in
            Rectangle().fill(.clear).contentShape(Rectangle())
                .onTapGesture { location in
                    if let id = proxy.node(of: String.self, at: location) {
                        selectedNode = model.nodes.first { $0.id == id }
                    }
                }
        }
    }

    /// Shares `ConfidenceBadge`'s exact tier→color mapping (Docs/13 M6) rather than a second,
    /// driftable copy of the same four cases.
    private func color(for node: ArchitectureNode) -> Color {
        guard let tier = node.confidenceTier else {
            return .indigo  // structural/FACT-tier module node -- no confidence spectrum
        }
        return ConfidenceBadge.color(forTier: tier)
    }

    private func radius(for node: ArchitectureNode) -> CGFloat {
        node.confidenceTier == nil ? 8 : min(24, 8 + sqrt(Double(node.size)) * 3)
    }
}
