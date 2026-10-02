import SwiftUI

/// The loaded architecture, or why it isn't there.
struct ArchitectureContent: View {
    let model: ArchitectureModel?
    let loadError: String?
    let shell: AppShellState

    var body: some View {
        if let loadError {
            ContentUnavailableView(
                "Couldn't Load Architecture", systemImage: "exclamationmark.triangle",
                description: Text(loadError))
        } else if let model {
            VStack(spacing: 0) {
                ArchitectureLayerBar(model: model, shell: shell)
                Divider()
                if model.nodes.isEmpty {
                    ContentUnavailableView(
                        "No Architecture Yet", systemImage: "square.dashed",
                        description: Text("Analysis didn't find any modules to show."))
                } else if shell.viewMode == .diagram {
                    ArchitectureDiagramView(model: model, spread: 1.6, labelsOnMaterial: true, zoomable: true) { node in
                        shell.inspectorContent = .node(node, model.layer)
                    }
                } else {
                    ComponentTable(model: model, shell: shell)
                }
            }
        } else {
            ProgressView("Loading architecture…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
