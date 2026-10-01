import SwiftUI

/// A component's name, status and purpose, at the top of its screen.
struct ComponentHeader: View {
    let detail: ComponentDetail

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
            Text(detail.name)
                .font(.title2)
                .bold()
            AdaptiveStack {
                EpistemicBadge(rawValue: detail.epistemicType)
                if let tier = detail.confidenceTier {
                    ConfidenceBadge(tier: tier)
                }
            }
            if detail.isStructural {
                Label("Structure from the code alone; no architecture model groups it.", systemImage: "cube")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            if let subtitle = detail.subtitle {
                MarkdownText(raw: subtitle)
                    .textSelection(.enabled)
            }
        }
        .padding(.vertical, DesignTokens.Spacing.xs)
    }
}
