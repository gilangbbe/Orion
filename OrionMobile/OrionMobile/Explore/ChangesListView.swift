import SwiftUI

/// Model Changes on the phone (Docs/19 M4, redesigned in M8): every update to Orion's
/// understanding of the code, each opening its full Previously / Now / Reason
/// (`ModelChangeDetailView`, the Mac's own).
struct ChangesListView: View {
    let outputDirectory: URL
    /// Arriving from a claim's "Superseded — see Model Changes": that revision's change opens.
    let focusRevisionId: String?
    let open: (ExploreRoute) -> Void

    @State private var entries: [ModelChangeSummary]?
    @State private var loadError: String?

    var body: some View {
        Group {
            if let loadError {
                ContentUnavailableView(
                    "Couldn't Load Model Changes", systemImage: "exclamationmark.triangle",
                    description: Text(loadError))
            } else if let entries, entries.isEmpty {
                ContentUnavailableView(
                    "No Model Changes Yet", systemImage: "clock.arrow.circlepath",
                    description: Text("When Orion's understanding of this code changes, the change shows up here."))
            } else if let entries {
                List(entries) { entry in
                    NavigationLink(value: ExploreRoute.change(entry)) {
                        ModelChangeRow(entry: entry)
                    }
                }
            } else {
                ProgressView()
            }
        }
        .navigationTitle("Model Changes")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private func load() async {
        guard entries == nil else { return }
        let outputDirectory = outputDirectory
        do {
            let loaded = try await Task.detached(priority: .userInitiated) {
                try ModelChangeLoader.load(outputDirectory: outputDirectory)
            }.value
            entries = loaded
            if let focusRevisionId, let match = loaded.first(where: { $0.id.hasPrefix("\(focusRevisionId)-") }) {
                open(.change(match))
            }
        } catch {
            loadError = String(describing: error)
        }
    }
}
