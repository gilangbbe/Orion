import OrionCore
import SwiftUI

/// A tab's content for the open repository -- rebuilt when the repository or its knowledge
/// changes (`generation`), so a re-import is shown at once. With no repository open, the next
/// step: Library (the HIG's "provide clear next steps on any blank screens").
struct RepositoryScoped<Content: View>: View {
    let library: LibraryModel
    let showLibrary: () -> Void
    @ViewBuilder let content: (LocalLibrary.Entry) -> Content

    var body: some View {
        if let entry = library.selected {
            content(entry)
                .id("\(entry.libraryKey)-\(library.generation)")
        } else {
            ContentUnavailableView {
                Label("No Repository Open", systemImage: "books.vertical")
            } description: {
                Text("Repositories analyzed by Orion on your Mac appear in Library.")
            } actions: {
                Button("Open Library", action: showLibrary)
                    .buttonStyle(.borderedProminent)
            }
        }
    }
}
