import OrionCore
import SwiftUI

/// The repository at a glance: what it is and how Orion sees it, the ways in (map, open questions,
/// model changes), and every component -- searchable by name or purpose.
struct ExploreHomeList: View {
    let entry: LocalLibrary.Entry
    let model: ArchitectureModel
    @Binding var selection: ExploreRoute?
    @Binding var searchText: String

    var body: some View {
        let nodes = Self.filter(model.nodes, by: searchText)
        List(selection: $selection) {
            if searchText.isEmpty {
                Section {
                    RepositorySummary(manifest: entry.manifest, layer: model.layer)
                }
                Section {
                    if MapScreen.canDraw(model) {
                        NavigationLink(value: ExploreRoute.map) {
                            Label("Map", systemImage: "point.3.filled.connected.trianglepath.dotted")
                        }
                    } else if !model.nodes.isEmpty {
                        Label {
                            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                                Text("Map")
                                Text("\(model.nodes.count, format: .number) \(ExploreView.nodesTitle(model.layer).lowercased()) are too many to draw. Use the list or search.")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "point.3.filled.connected.trianglepath.dotted")
                        }
                        .foregroundStyle(.secondary)
                    }
                    if !model.uncertainties.isEmpty {
                        NavigationLink(value: ExploreRoute.openQuestions) {
                            LabeledContent {
                                Text(model.uncertainties.count, format: .number)
                            } label: {
                                Label("Open Questions", systemImage: "questionmark.circle")
                            }
                        }
                    }
                    NavigationLink(value: ExploreRoute.changes(focusRevisionId: nil)) {
                        Label("Model Changes", systemImage: "clock.arrow.circlepath")
                    }
                }
            }
            if model.nodes.isEmpty {
                ContentUnavailableView(
                    "No Architecture Yet", systemImage: "square.dashed",
                    description: Text("This snapshot's analysis produced no modules to show."))
            } else {
                Section(ExploreView.nodesTitle(model.layer)) {
                    ForEach(nodes) { node in
                        NavigationLink(value: ExploreRoute.component(id: node.id)) {
                            ComponentRow(node: node)
                        }
                        .accessibilityIdentifier("explore.component")
                    }
                }
            }
        }
        .searchable(text: $searchText, prompt: "Find a component")
        .overlay {
            if !searchText.isEmpty, nodes.isEmpty {
                ContentUnavailableView.search
            }
        }
    }

    /// Components whose name or purpose mention the search text.
    static func filter(_ nodes: [ArchitectureNode], by text: String) -> [ArchitectureNode] {
        let query = text.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return nodes }
        return nodes.filter {
            $0.name.localizedStandardContains(query) || ($0.subtitle?.localizedStandardContains(query) ?? false)
        }
    }
}
