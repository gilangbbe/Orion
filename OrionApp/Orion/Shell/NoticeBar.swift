import SwiftUI

/// A one-line notice with a close button: an error to dismiss, or a pending state to cancel.
struct NoticeBar: View {
    let message: String
    let systemImage: String
    let tint: Color
    let dismiss: () -> Void
    var dismissLabel = "Dismiss"

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            Label(message, systemImage: systemImage)
                .foregroundStyle(tint)
                .lineLimit(2)
            Spacer(minLength: 0)
            Button(dismissLabel, systemImage: "xmark.circle.fill", action: dismiss)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help(dismissLabel)
        }
        .font(.callout)
        .padding(.horizontal, DesignTokens.Spacing.md)
        .padding(.vertical, DesignTokens.Spacing.sm)
        .background(tint.opacity(0.12), in: .rect(cornerRadius: DesignTokens.Radius.control))
    }
}
