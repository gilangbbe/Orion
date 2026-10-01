import SwiftUI

/// The question field and send button, on Liquid Glass at the bottom of the conversation.
struct AskComposer: View {
    @Binding var draft: String
    let prompt: String
    let isAsking: Bool
    var focused: FocusState<Bool>.Binding
    let send: () -> Void

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isAsking
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: DesignTokens.Spacing.sm) {
            TextField(prompt, text: $draft, axis: .vertical)
                .lineLimit(1...5)
                .focused(focused)
                .submitLabel(.send)
                .padding(.horizontal, DesignTokens.Spacing.lg)
                .padding(.vertical, DesignTokens.Spacing.md)
                .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 22))
                // A multi-line field's return key inserts a newline instead of submitting, so a
                // typed newline *is* the send (Docs/19 M6, caught by the Ask walkthrough).
                .onChange(of: draft) { _, newValue in
                    guard newValue.contains("\n") else { return }
                    draft = newValue.replacing("\n", with: " ")
                    if canSend { send() }
                }
            Button("Send", systemImage: "arrow.up", action: send)
                .labelStyle(.iconOnly)
                .font(.title3.bold())
                .buttonStyle(.glassProminent)
                .buttonBorderShape(.circle)
                .controlSize(.large)
                .disabled(!canSend)
                .accessibilityIdentifier("ask.send")
        }
        .padding(.horizontal)
        .padding(.vertical, DesignTokens.Spacing.sm)
    }
}
