import SwiftUI

/// An open repository (Docs/14 §4.1, redesigned in Docs/20 R1): the sidebar of destinations and
/// the selected destination. The window's title is the repository and its subtitle the
/// destination -- "Give each window a useful title to confirm location and distinguish windows"
/// (HIG, Toolbars). Repository actions live in the toolbar and the menu bar, not the sidebar.
struct RepositoryWindowView: View {
    let window: RepositoryWindow
    @Bindable var shell: AppShellState
    let summary: RepositorySummary

    var body: some View {
        NavigationSplitView {
            SidebarView(window: window, shell: shell)
                .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 300)
        } detail: {
            DestinationView(window: window, shell: shell, summary: summary)
        }
        .navigationTitle(summary.repoRoot.lastPathComponent)
        .navigationSubtitle(shell.destination.title)
        .toolbarTitleMenu {
            RepositoryTitleMenu(window: window)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                SyncToolbarButton(window: window)
            }
        }
        .task(id: shell.destination) { await window.refreshBadges() }
    }
}
