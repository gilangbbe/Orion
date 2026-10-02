import SwiftUI

/// "Open Recent": recognizable names, most recent first, with Clear Menu (HIG, File menu). Used by
/// the File menu and the window title's menu.
struct RecentRepositoriesMenu: View {
    /// `nil` when no window is in front: the items show, disabled.
    let window: RepositoryWindow?
    var recents: RecentRepositoriesModel?

    var body: some View {
        let model = recents ?? window?.recents
        Menu("Open Recent") {
            ForEach(model?.entries ?? []) { entry in
                Button(entry.displayName) { window?.reopen(entry) }
                    .disabled(window == nil)
            }
            Divider()
            Button("Clear Menu") { model?.clear() }
                .disabled(model?.entries.isEmpty ?? true)
        }
    }
}
