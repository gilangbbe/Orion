import SwiftUI

/// Architecture's toolbar items, each also in the menu bar: Repository > Build Architecture
/// Model…, View > Architecture as Diagram/List, View > Show Inspector.
struct ArchitectureToolbar: ToolbarContent {
    let window: RepositoryWindow
    @Bindable var shell: AppShellState

    var body: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Picker("View", selection: $shell.viewMode) {
                ForEach(ArchitectureViewMode.allCases) { mode in
                    Label(mode.rawValue, systemImage: mode.systemImage)
                        .tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .help("Show the architecture as a diagram or a table")
        }
        ToolbarItem(placement: .primaryAction) {
            BuildModelToolbarButton(window: window)
        }
        ToolbarItem(placement: .primaryAction) {
            Button("Inspector", systemImage: "sidebar.trailing", action: toggleInspector)
                .help(shell.isInspectorPresented ? "Hide the inspector" : "Show the inspector")
        }
    }

    private func toggleInspector() {
        shell.isInspectorPresented.toggle()
    }
}
