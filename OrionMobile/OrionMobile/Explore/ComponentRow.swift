import SwiftUI

/// A component in Explore's list: its name, the first lines of its purpose, and its confidence
/// when that's less than high. Read by VoiceOver as one element.
struct ComponentRow: View {
    let node: ArchitectureNode

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            Text(node.name)
            if let subtitle = node.subtitle, !subtitle.isEmpty {
                Text(PlainText.from(markdown: subtitle))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .scaledLineLimit(2)
            }
            if let tier = node.confidenceTier {
                ConfidenceNote(tier: tier)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}
