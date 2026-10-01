import SwiftUI

/// The question being answered, and the answer as it streams in.
struct PendingTurnView: View {
    let question: String
    let streamingAnswer: String

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
            QuestionBubble(text: question)
            if streamingAnswer.isEmpty {
                Label {
                    Text("Looking through the repository…")
                } icon: {
                    ProgressView()
                }
                .foregroundStyle(.secondary)
            } else {
                MarkdownText(raw: streamingAnswer)
            }
        }
    }
}
