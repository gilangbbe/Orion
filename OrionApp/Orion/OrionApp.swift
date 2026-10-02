import SwiftUI

/// Docs/13: the app shell. Docs/20 R1: each window opens its own repository; the menu bar acts on
/// the one in front; Settings lists what syncs to the iPhone.
@main
struct OrionApp: App {
    @State private var recents = RecentRepositoriesModel()

    var body: some Scene {
        WindowGroup {
            ContentView(recents: recents)
        }
        .commands {
            OrionCommands(recents: recents)
        }

        Settings {
            SettingsView(sync: .shared)
        }
    }
}
