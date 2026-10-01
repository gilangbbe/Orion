import SwiftUI

/// The result of the last import, until dismissed.
struct LibraryMessageBar: View {
    let message: LibraryModel.Message
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            Image(systemName: message.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(message.isError ? .orange : .green)
                .accessibilityHidden(true)
            Text(message.text)
                .font(.subheadline)
            Spacer(minLength: 0)
            Button("Dismiss", systemImage: "xmark", action: dismiss)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .frame(minWidth: 44, minHeight: 44)
        }
        .padding(.leading, DesignTokens.Spacing.md)
        .glassEffect(in: .rect(cornerRadius: DesignTokens.Radius.panel))
        .padding(.horizontal)
        .padding(.bottom, DesignTokens.Spacing.sm)
    }
}
