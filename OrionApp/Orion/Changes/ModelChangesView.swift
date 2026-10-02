import SwiftUI

/// Model Changes (Docs/05 Stage 6, Docs/14 §4.7, Docs/16 §8 M5): every time Orion's understanding
/// of the code changed, newest first, and the selected one in full -- Previously, Now, Reason.
///
/// Master/detail, not inline disclosure (Docs/14 §12.4): the three fields are paragraphs of prose,
/// which belong in a detail area. Docs/20 R6: the list is a native `List(selection:)` rather than
/// hand-built buttons; the detail is shared with the iPhone (`ModelChangeDetailView`).
struct ModelChangesView: View {
    let outputDirectory: URL
    /// Set by a `CONTRADICTED` claim's "Superseded — see Model Changes": that revision is selected
    /// on arrival. Otherwise the newest change is.
    let focusedRevisionId: String?

    @State private var entries: [ModelChangeSummary]?
    @State private var loadError: String?
    @State private var selection: ModelChangeSummary.ID?

    var body: some View {
        Group {
            if let loadError {
                ContentUnavailableView(
                    "Couldn't Load Model Changes", systemImage: "exclamationmark.triangle",
                    description: Text(loadError))
            } else if let entries, entries.isEmpty {
                ContentUnavailableView(
                    "No Model Changes Yet", systemImage: "clock.arrow.circlepath",
                    description: Text("When a new analysis or investigation changes what Orion believes about the code, the change and its reason appear here."))
            } else if let entries {
                HSplitView {
                    ModelChangeList(entries: entries, selection: $selection)
                        .frame(minWidth: 280, idealWidth: 280, maxWidth: 280, maxHeight: .infinity)
                    ModelChangeDetailPane(entry: entries.first { $0.id == selection })
                        .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task { await load() }
    }

    private func load() async {
        let outputDirectory = outputDirectory
        do {
            let loaded = try await Task.detached(priority: .userInitiated) {
                try ModelChangeLoader.load(outputDirectory: outputDirectory)
            }.value
            entries = loaded
            selection = Self.initialSelection(in: loaded, focusedRevisionId: focusedRevisionId)
        } catch {
            loadError = String(describing: error)
        }
    }

    /// The focused revision's first row when arriving from a "Superseded" link; otherwise the newest
    /// change (the loader returns newest first), so the detail is never blank on arrival.
    static func initialSelection(in entries: [ModelChangeSummary], focusedRevisionId: String?) -> String? {
        if let focusedRevisionId, let match = entries.first(where: { $0.id.hasPrefix("\(focusedRevisionId)-") }) {
            return match.id
        }
        return entries.first?.id
    }
}
