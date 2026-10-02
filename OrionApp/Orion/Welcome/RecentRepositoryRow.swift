import SwiftUI

/// A recent repository: its name, and where it is -- a folder path, or the GitHub URL it was
/// cloned from.
struct RecentRepositoryRow: View {
    let entry: RecentRepositoryEntry

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.displayName)
                Text(location)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        } icon: {
            Image(systemName: isGitHub ? "network" : "folder")
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
        .help(entry.input)
    }

    private var isGitHub: Bool {
        entry.input.lowercased().hasPrefix("https://")
    }

    /// Paths under the home folder are shown as `~/…`, like Finder's Go menu.
    private var location: String {
        guard !isGitHub else { return entry.input }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return entry.input.hasPrefix(home) ? "~" + entry.input.dropFirst(home.count) : entry.input
    }
}
