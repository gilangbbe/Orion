import SwiftUI

/// Learn's leading column: why it can't run, nothing to practise yet, or the concepts.
struct LearnSidebar: View {
    let model: LearnModel
    @Binding var selection: String?

    var body: some View {
        if model.availability != .available {
            ModelUnavailableView(availability: model.availability, feature: "Learn", onRetry: model.refreshAvailability)
        } else if let error = model.loadError {
            ContentUnavailableView("Couldn't Load Concepts", systemImage: "exclamationmark.triangle", description: Text(error))
        } else if model.concepts.isEmpty {
            ContentUnavailableView {
                Label("No Concepts Yet", systemImage: "graduationcap")
            } description: {
                Text("Open this repository's Teaching Mode on your Mac once, then sync it again. Its concepts come from the Mac's analysis.")
            }
        } else {
            LearnConceptList(model: model, selection: $selection)
        }
    }
}
