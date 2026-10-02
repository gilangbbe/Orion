import SwiftUI

/// Architecture as a table (Docs/20 R3): every component with its purpose, size and confidence,
/// sortable by clicking a column heading (HIG, Lists and tables, macOS). Selecting a row opens it
/// in the inspector. Also the diagram's fully accessible equivalent (Docs/13 M8): Grape draws on a
/// canvas VoiceOver can't read, a table it can.
struct ComponentTable: View {
    let model: ArchitectureModel
    let shell: AppShellState

    @State private var sortOrder = [KeyPathComparator(\ArchitectureNode.name, comparator: .localizedStandard)]
    @State private var selection: ArchitectureNode.ID?

    var body: some View {
        let nodes = model.nodes.sorted(using: sortOrder)
        Table(nodes, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Component", value: \.name, comparator: .localizedStandard)
            TableColumn("Purpose") { node in
                Text(node.subtitle ?? "")
                    .foregroundStyle(.secondary)
                    .help(node.subtitle ?? "")
            }
            TableColumn("Members", value: \.size) { node in
                Text(node.size, format: .number)
                    .monospacedDigit()
            }
            .width(min: 60, ideal: 70, max: 90)
            TableColumn("Confidence", value: \.confidenceRank) { node in
                if let tier = node.confidenceTier {
                    ConfidenceBadge(tier: tier)
                }
            }
            .width(min: 90, ideal: 110, max: 140)
        }
        .onChange(of: selection) { _, id in select(id) }
        .onChange(of: shell.inspectorContent) { _, content in
            // Closing the inspector, or opening Open Questions, clears the row.
            if case .node(let node, _) = content {
                selection = node.id
            } else {
                selection = nil
            }
        }
        .onAppear(perform: syncSelectionFromInspector)
    }

    private func select(_ id: ArchitectureNode.ID?) {
        guard let id, let node = model.nodes.first(where: { $0.id == id }) else { return }
        if case .node(let current, _) = shell.inspectorContent, current.id == id { return }
        shell.inspectorContent = .node(node, model.layer)
    }

    private func syncSelectionFromInspector() {
        if case .node(let node, _) = shell.inspectorContent {
            selection = node.id
        }
    }
}
