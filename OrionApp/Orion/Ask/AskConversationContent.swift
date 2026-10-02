import SwiftUI

/// The selected session's transcript; otherwise what asking will start.
struct AskConversationContent: View {
    let history: AskHistory
    let isSubmitting: Bool
    let repoRoot: URL
    let shellState: AppShellState

    var body: some View {
        if let session = history.sessions.first(where: { $0.id == history.selectedSessionID }) {
            AskTranscript(
                title: session.title, turns: history.turns, isSubmitting: isSubmitting,
                repoRoot: repoRoot, shellState: shellState)
        } else if let scope = history.pendingScope {
            ContentUnavailableView(
                "New Session About \(scope)", systemImage: "bubble.left.and.text.bubble.right",
                description: Text("Ask your first question below to start it."))
        } else {
            ContentUnavailableView(
                "Ask About \(repoRoot.lastPathComponent)", systemImage: "bubble.left.and.text.bubble.right",
                description: Text("Ask how something works or where it lives. Answers cite the code they rest on, and say how sure they are."))
        }
    }
}
