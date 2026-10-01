import SwiftUI

/// The learner's question, trailing, in a neutral bubble -- the familiar messaging shape. Neutral
/// fill rather than the accent: the bubble isn't tappable.
struct QuestionBubble: View {
    let text: String

    var body: some View {
        HStack {
            Spacer(minLength: 48)
            Text(text)
                .padding(.horizontal, DesignTokens.Spacing.md)
                .padding(.vertical, DesignTokens.Spacing.sm)
                .background(.fill.secondary, in: .rect(cornerRadius: DesignTokens.Radius.window))
                .textSelection(.enabled)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("You asked: \(text)")
    }
}
