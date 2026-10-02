import SwiftUI

/// The destinations, and nothing else (Docs/20 R1). Repository actions moved to the toolbar and
/// menu bar: "Keep critical information/actions away from the bottom, which may be offscreen"
/// (HIG, Sidebars). Counts use the native badge: unread Model Changes (Docs/16 §8 M5) and Learn's
/// open misconceptions (Docs/17 §11).
struct SidebarView: View {
    let window: RepositoryWindow
    @Bindable var shell: AppShellState

    var body: some View {
        List(selection: $shell.destination) {
            Section {
                ForEach(Destination.primary) { destination in
                    Label(destination.title, systemImage: destination.systemImage)
                        .badge(badge(for: destination))
                        .tag(destination)
                }
            }
            Section("Advanced") {
                ForEach(Destination.advanced) { destination in
                    Label(destination.title, systemImage: destination.systemImage)
                        .tag(destination)
                }
            }
        }
    }

    private func badge(for destination: Destination) -> Int {
        switch destination {
        case .changes: window.unreadModelChanges
        case .teaching: window.teaching.overview.misconceptionConcepts
        default: 0
        }
    }
}
