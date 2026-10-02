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
