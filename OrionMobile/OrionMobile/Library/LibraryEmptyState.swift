import SwiftUI

/// No repositories yet: how to get one, with the import as the action.
struct LibraryEmptyState: View {
    let noAccount: Bool
    let importSnapshot: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("No Repositories Yet", systemImage: "books.vertical")
        } description: {
            Text(noAccount
                ? "Sign in to iCloud in Settings, then turn on Sync to iPhone for a repository in Orion on your Mac. You can also import a .orionsnap snapshot."
                : "In Orion on your Mac, turn on Sync to iPhone for a repository and it appears here. You can also import a .orionsnap snapshot.")
        } actions: {
            Button("Import Snapshot…", action: importSnapshot)
                .buttonStyle(.borderedProminent)
        }
    }
}
