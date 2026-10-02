import SwiftUI

/// The component's name, what kind of knowledge it is and how confident, and Ask About This.
struct ComponentHeader: View {
    let detail: ComponentDetail
    let askAbout: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            Text(detail.name)
                .font(.title2.bold())
                .textSelection(.enabled)
            HStack(spacing: DesignTokens.Spacing.sm) {
                EpistemicBadge(rawValue: detail.epistemicType)
                if let tier = detail.confidenceTier {
                    ConfidenceBadge(tier: tier)
                }
            }
            if detail.isStructural {
                Label("Structural view: from deterministic analysis only, not a semantic grouping.", systemImage: "cube")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Button("Ask About This", systemImage: "bubble.left.and.text.bubble.right", action: askAbout)
                .padding(.top, DesignTokens.Spacing.xs)
        }
    }
}
