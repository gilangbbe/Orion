import SwiftUI

extension EnvironmentValues {
    /// Switches to the Library tab -- from a repository title menu's "Manage Repositories" or an
    /// empty state (Docs/19 M8).
    @Entry var showLibrary: @MainActor () -> Void = {}
}
