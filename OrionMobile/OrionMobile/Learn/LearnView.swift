import OrionCore
import SwiftUI

/// The Learn tab (Docs/19 M7, redesigned in M8): the repository's concepts, ranked by what's most
/// useful to practise next, beside the practice screen for the chosen one.
struct LearnView: View {
    @State private var model: LearnModel
    @State private var selection: String?

    init(entry: LocalLibrary.Entry) {
        _model = State(initialValue: LearnModel(entry: entry))
    }

    var body: some View {
        NavigationSplitView {
            LearnSidebar(model: model, selection: $selection)
                .repositoryTitleMenu()
        } detail: {
            NavigationStack {
                if let selection {
                    LearnPracticeView(model: model, conceptId: selection)
                } else {
                    ContentUnavailableView(
                        "Choose a Concept", systemImage: "graduationcap",
                        description: Text("Pick a concept to practise, or start with the one that's up next."))
                }
            }
        }
        .task {
            model.refresh()
            model.prewarm()
        }
        // Opening and closing a concept follows the selection, not the practice view's appearance:
        // on iPad a new practice view can appear before the old one disappears.
        .onChange(of: selection) { _, newValue in
            if let newValue {
                model.open(conceptId: newValue)
            } else if !model.isBusy {
                model.close()
            }
        }
    }
}
