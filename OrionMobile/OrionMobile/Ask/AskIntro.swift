import SwiftUI

/// An empty conversation: what Ask is, and a few questions to start with.
struct AskIntro: View {
    let title: String
    let suggestions: [String]
    let ask: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.lg) {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
                Text(title)
                    .font(.title2)
                    .bold()
                Text("Answers come from Apple's on-device model, grounded in this repository's analyzed knowledge. Nothing leaves your iPhone.")
                    .foregroundStyle(.secondary)
            }
            if !suggestions.isEmpty {
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
                    Text("Try asking")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    ForEach(suggestions, id: \.self) { suggestion in
                        Button {
                            ask(suggestion)
                        } label: {
                            Label(suggestion, systemImage: "sparkle.magnifyingglass")
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .multilineTextAlignment(.leading)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                        .accessibilityIdentifier("ask.suggestion")
                    }
                }
            }
        }
        .padding(.top, DesignTokens.Spacing.lg)
    }
}
