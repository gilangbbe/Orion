import SwiftUI

/// The window title's menu: other repositories, and where this one lives.
struct RepositoryTitleMenu: View {
    let window: RepositoryWindow

    var body: some View {
        Button("Show in Finder", systemImage: "folder", action: window.showInFinder)
        Divider()
        RecentRepositoriesMenu(window: window)
        Button("Open Repository…", systemImage: "folder.badge.plus") { window.isPickingFolder = true }
        Button("Clone from GitHub…", systemImage: "arrow.down.circle") { window.isCloning = true }
    }
}
