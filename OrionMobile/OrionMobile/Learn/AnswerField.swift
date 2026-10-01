import SwiftUI

/// Where the learner writes the answer.
struct AnswerField: View {
    @Binding var text: String
    var focused: FocusState<Bool>.Binding

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            Text("Your answer")
                .font(.subheadline.bold())
                .foregroundStyle(.secondary)
            TextField("Explain it in your own words…", text: $text, axis: .vertical)
                .lineLimit(5...12)
                .focused(focused)
                .padding(DesignTokens.Spacing.md)
                .background(.fill.tertiary, in: .rect(cornerRadius: DesignTokens.Radius.panel))
                .accessibilityIdentifier("learn.answer")
        }
    }
}
