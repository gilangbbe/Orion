import SwiftUI

/// The sessions, grouped by what they're about. Right-click for Rename, a new session in the same
/// group, or Delete (Docs/15 §4.7).
struct AskSessionList: View {
    @Bindable var history: AskHistory
    let search: String
    let outputDirectory: URL
    let rename: (AskSessionRow) -> Void
    let delete: (AskSessionRow) -> Void

    var body: some View {
        let groups = history.groups(matching: search)
        List(selection: $history.selectedSessionID) {
            ForEach(groups) { group in
                Section(group.name) {
                    ForEach(group.sessions) { session in
                        AskSessionRowView(session: session)
                            .tag(session.id)
                            .contextMenu {
                                Button("Rename…") { rename(session) }
                                Button(group.name == "General" ? "New General Session" : "New Session About \(group.name)") {
                                    startSession(in: group)
                                }
                                Divider()
                                Button("Delete…", role: .destructive) { delete(session) }
                            }
                    }
                }
            }
        }
        .overlay {
            if history.sessions.isEmpty {
                ContentUnavailableView(
                    "No Sessions", systemImage: "bubble.left.and.text.bubble.right",
                    description: Text("Your questions and their answers are kept here."))
            } else if groups.isEmpty {
                ContentUnavailableView.search(text: search)
            }
        }
        .onChange(of: history.selectedSessionID) { _, id in load(id) }
    }

    private func load(_ id: String?) {
        guard let id else { return }
        Task { await history.select(id, outputDirectory: outputDirectory) }
    }

    private func startSession(in group: AskHistory.Group) {
        Task {
            await history.startSession(forGroupNamed: group.name, componentId: group.componentId, outputDirectory: outputDirectory)
        }
    }
}
