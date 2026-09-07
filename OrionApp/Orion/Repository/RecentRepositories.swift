import Foundation

/// One entry in the recently-opened list -- `input` is the raw string the user typed/picked (a
/// local path or a GitHub URL), used both to display and to re-derive a `RepositorySession.Input`
/// on reopen.
struct RecentRepositoryEntry: Codable, Identifiable, Equatable {
    var id: String { input }
    let input: String
    let displayName: String
    let lastOpened: Date
}

/// A small JSON file under Application Support -- app-shell convenience state (Docs/13
/// M1's own distinction), not the Codebase Model. Losing this file loses only the recents list,
/// never anything about a repository's own analysis.
struct RecentRepositories {
    private let fileURL: URL
    private let maxEntries: Int
    private let fileManager: FileManager

    init(
        fileURL: URL = AppPaths.recentRepositoriesFile, maxEntries: Int = 10,
        fileManager: FileManager = .default
    ) {
        self.fileURL = fileURL
        self.maxEntries = maxEntries
        self.fileManager = fileManager
    }

    /// Most-recently-opened first.
    func load() -> [RecentRepositoryEntry] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return (try? JSONDecoder().decode([RecentRepositoryEntry].self, from: data)) ?? []
    }

    /// Moves `input` to the front (updating its timestamp/display name) if already present,
    /// else inserts it, then trims to `maxEntries`.
    func recordOpened(input: String, displayName: String, now: Date = Date()) {
        var entries = load().filter { $0.input != input }
        entries.insert(
            RecentRepositoryEntry(input: input, displayName: displayName, lastOpened: now), at: 0)
        if entries.count > maxEntries {
            entries.removeLast(entries.count - maxEntries)
        }
        save(entries)
    }

    private func save(_ entries: [RecentRepositoryEntry]) {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? fileManager.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }
}
