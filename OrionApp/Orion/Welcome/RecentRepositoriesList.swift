import SwiftUI

/// Recently opened repositories, newest first. Double-click or Return opens one.
struct RecentRepositoriesList: View {
    let entries: [RecentRepositoryEntry]
    let open: (RecentRepositoryEntry) -> Void

    @State private var selection: RecentRepositoryEntry.ID?

    var body: some View {
        List(selection: $selection) {
            Section("Recent") {
                ForEach(entries) { entry in
                    RecentRepositoryRow(entry: entry)
                }
            }
        }
        .contextMenu(forSelectionType: RecentRepositoryEntry.ID.self) { ids in
            if let entry = entry(for: ids) {
                Button("Open") { open(entry) }
            }
        } primaryAction: { ids in
            if let entry = entry(for: ids) {
                open(entry)
            }
        }
        .overlay {
            if entries.isEmpty {
                ContentUnavailableView(
                    "No Recent Repositories", systemImage: "clock",
                    description: Text("Repositories you open appear here."))
            }
        }
    }

    private func entry(for ids: Set<RecentRepositoryEntry.ID>) -> RecentRepositoryEntry? {
        guard let id = ids.first else { return nil }
        return entries.first { $0.id == id }
    }
}
