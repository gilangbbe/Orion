import SwiftUI

/// Where a question is typed: a field that grows with the question, and Ask. Return asks;
/// Option-Return starts a new line.
struct AskComposer: View {
    @Binding var text: String
    let placeholder: String
    let isSubmitting: Bool
    let submit: () -> Void

    var body: some View {
        HStack(alignment: .bottom, spacing: DesignTokens.Spacing.sm) {
            TextField(placeholder, text: $text, axis: .vertical)
                .lineLimit(1...6)
                .textFieldStyle(.roundedBorder)
                .onSubmit(submit)
                .disabled(isSubmitting)
            Button(action: submit) {
                if isSubmitting {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Answering")
                } else {
                    Text("Ask")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(isSubmitting || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }
}
