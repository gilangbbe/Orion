import SwiftUI

/// The screen for one Explore route -- the detail column's root, and every push within it.
struct ExploreDetail: View {
    let route: ExploreRoute?
    let model: ArchitectureModel?
    let outputDirectory: URL
    let onAskAbout: ((ComponentDetail) -> Void)?
    let open: (ExploreRoute) -> Void

    var body: some View {
        switch route {
        case nil:
            ContentUnavailableView(
                "Choose a Component", systemImage: "square.stack.3d.up",
                description: Text("Pick a component, the map, open questions or model changes."))
        case .map:
            if let model {
                MapScreen(model: model, open: open)
            }
        case .openQuestions:
            OpenQuestionsScreen(uncertainties: model?.uncertainties ?? [])
        case .changes(let focusRevisionId):
            ChangesListView(outputDirectory: outputDirectory, focusRevisionId: focusRevisionId, open: open)
        case .change(let entry):
            ModelChangeDetailView(entry: entry)
                .navigationTitle("Change")
                .navigationBarTitleDisplayMode(.inline)
        case .component(let id):
            if let model, let node = model.nodes.first(where: { $0.id == id }) {
                ComponentScreen(
                    outputDirectory: outputDirectory, node: node, model: model, onAskAbout: onAskAbout,
                    open: open)
            } else {
                ContentUnavailableView("Component Not Found", systemImage: "questionmark.square.dashed")
            }
        }
    }
}
