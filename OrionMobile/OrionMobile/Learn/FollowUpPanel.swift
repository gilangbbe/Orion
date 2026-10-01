import SwiftUI

/// The question's transfer problem, to think about next (not graded).
struct FollowUpPanel: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            Label("To think about next", systemImage: "lightbulb")
                .font(.subheadline.bold())
                .foregroundStyle(.secondary)
            MarkdownText(raw: text)
        }
    }
}
