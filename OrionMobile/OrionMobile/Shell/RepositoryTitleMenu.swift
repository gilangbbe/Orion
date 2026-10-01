import OrionCore
import SwiftUI

/// The open repository's name as the navigation title, with a title menu that switches to another
/// repository on this device (Docs/19 M8) -- so changing repository isn't a trip to Library.
struct RepositoryTitleMenu: ViewModifier {
    @Environment(LibraryModel.self) private var library
    @Environment(\.showLibrary) private var showLibrary

    func body(content: Content) -> some View {
        content
            .navigationTitle(library.selected?.manifest.repositoryName ?? "")
            .toolbarTitleMenu {
                ForEach(library.entries, id: \.libraryKey) { entry in
                    Button {
                        library.selectedKey = entry.libraryKey
                    } label: {
                        if entry.libraryKey == library.selectedKey {
                            Label(entry.manifest.repositoryName, systemImage: "checkmark")
                        } else {
                            Text(entry.manifest.repositoryName)
                        }
                    }
                }
                Divider()
                Button("Manage Repositories", systemImage: "books.vertical", action: showLibrary)
            }
    }
}

extension View {
    /// The repository's name as the title, switchable from its title menu.
    func repositoryTitleMenu() -> some View {
        modifier(RepositoryTitleMenu())
    }
}
