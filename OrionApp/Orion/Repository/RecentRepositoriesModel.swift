import Foundation

/// The recents list every window and File > Open Recent share (Docs/20 R1). An observable front
/// for `RecentRepositories`, which owns the file.
@MainActor
@Observable
final class RecentRepositoriesModel {
    private(set) var entries: [RecentRepositoryEntry] = []
    private let store: RecentRepositories

    init(store: RecentRepositories = RecentRepositories()) {
        self.store = store
        entries = store.load()
    }

    func record(input: String, displayName: String) {
        store.recordOpened(input: input, displayName: displayName)
        entries = store.load()
    }

    func clear() {
        store.clear()
        entries = []
    }

    /// What reopening `entry` means: a GitHub URL is cloned again, anything else is a folder.
    static func input(for entry: RecentRepositoryEntry) -> RepositorySession.Input {
        if let url = URL(string: entry.input), url.scheme?.lowercased() == "https" {
            .gitHubURL(url)
        } else {
            .localPath(URL(fileURLWithPath: entry.input))
        }
    }
}
