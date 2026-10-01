import SwiftUI

/// The submitted answer, read only.
struct AnswerQuote: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            Text("Your answer")
                .font(.subheadline.bold())
                .foregroundStyle(.secondary)
            Text(text)
                .foregroundStyle(.secondary)
                .padding(DesignTokens.Spacing.md)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.fill.quaternary, in: .rect(cornerRadius: DesignTokens.Radius.panel))
        }
    }
}
