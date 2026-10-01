import OrionCore
import SwiftUI

/// The repository's conversations, newest first; swipe to delete.
struct ConversationsList: View {
    let model: AskModel
    @Binding var selection: String?
    let startNew: () -> Void

    var body: some View {
        List(selection: $selection) {
            ForEach(model.sessions, id: \.id) { session in
                NavigationLink(value: session.id) {
                    VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                        Text(session.title)
                            .scaledLineLimit(2)
                        Text("^[\(session.turnCount) question](inflect: true)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                .swipeActions {
                    Button("Delete", systemImage: "trash", role: .destructive) { model.delete(session) }
                }
            }
        }
        .overlay {
            if model.sessions.isEmpty {
                ContentUnavailableView(
                    "No Conversations Yet", systemImage: "bubble.left.and.text.bubble.right",
                    description: Text("Questions you ask about this repository are kept here, on this device."))
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("New Conversation", systemImage: "square.and.pencil", action: startNew)
                    .disabled(model.isAsking)
            }
        }
    }
}
