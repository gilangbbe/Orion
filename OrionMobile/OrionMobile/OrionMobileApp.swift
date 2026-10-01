import OrionCore
import SwiftUI

/// The iOS companion (Docs/19): explore and learn a codebase analyzed by Orion on the Mac.
@main
struct OrionMobileApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}
