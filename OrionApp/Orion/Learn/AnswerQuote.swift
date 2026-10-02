import SwiftUI

/// Your answer, quoted back while it's graded and beside its grade.
struct AnswerQuote: View {
    let text: String

    var body: some View {
        LearnSection("Your Answer") {
            Text(text)
                .textSelection(.enabled)
                .padding(DesignTokens.Spacing.md)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: DesignTokens.Radius.control))
        }
    }
}
