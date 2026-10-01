import OrionCore
import SwiftUI

/// Explore's leading column: loading, failure, or the repository's overview list.
struct ExploreSidebar: View {
    let entry: LocalLibrary.Entry
    let model: ArchitectureModel?
    let loadError: String?
    @Binding var selection: ExploreRoute?
    @Binding var searchText: String

    var body: some View {
        if let loadError {
            ContentUnavailableView(
                "Couldn't Load the Architecture", systemImage: "exclamationmark.triangle",
                description: Text(loadError))
        } else if let model {
            ExploreHomeList(entry: entry, model: model, selection: $selection, searchText: $searchText)
        } else {
            ProgressView("Loading architecture…")
        }
    }
}
