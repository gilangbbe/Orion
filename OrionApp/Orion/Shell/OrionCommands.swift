import SwiftUI

/// The menu bar (Docs/20 R1). Every toolbar item has a command here, because "people can
/// customize or hide the toolbar" (HIG, Toolbars, macOS), and unavailable items are disabled, not
/// hidden (HIG, The menu bar). Commands act on the window in front, through
/// `FocusedValues.repositoryWindow`.
struct OrionCommands: Commands {
    let recents: RecentRepositoriesModel
    @FocusedValue(\.repositoryWindow) private var window

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About Orion", action: AboutPanel.show)
        }

        CommandGroup(after: .newItem) {
            Button("Open Repository…", action: openRepository)
                .keyboardShortcut("o")
                .disabled(window == nil)
            Button("Clone from GitHub…", action: cloneRepository)
                .keyboardShortcut("o", modifiers: [.command, .shift])
                .disabled(window == nil)
            RecentRepositoriesMenu(window: window, recents: recents)
            Divider()
            Button("Close Repository", action: closeRepository)
                .disabled(window?.summary == nil)
        }

        CommandGroup(before: .sidebar) {
            ForEach(Destination.allCases) { destination in
                Button(destination.title) { show(destination) }
                    .keyboardShortcut(destination.shortcut)
                    .disabled(window?.summary == nil)
            }
            Divider()
            ForEach(ArchitectureViewMode.allCases) { mode in
                Button("Architecture as \(mode.rawValue)") { showArchitecture(as: mode) }
                    .keyboardShortcut(mode == .diagram ? "1" : "2", modifiers: [.command, .control])
                    .disabled(window?.summary == nil)
            }
            Divider()
        }

        CommandMenu("Repository") {
            RepositoryMenuItems(window: window)
        }

        SidebarCommands()
        InspectorCommands()
        ToolbarCommands()
    }

    private func openRepository() {
        window?.isPickingFolder = true
    }

    private func cloneRepository() {
        window?.isCloning = true
    }

    private func closeRepository() {
        window?.closeRepository()
    }

    private func show(_ destination: Destination) {
        window?.shell.destination = destination
    }

    private func showArchitecture(as mode: ArchitectureViewMode) {
        window?.shell.destination = .overview
        window?.shell.viewMode = mode
    }
}
