import SwiftUI

/// Everything the investigation couldn't settle (Docs/13 M6), in Architecture's inspector. Some
/// run to 200 words, so they live here, reached from the layer bar, not above the diagram
/// (Docs/14 §8 M3).
struct OpenQuestionsPanel: View {
    let uncertainties: [String]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.lg) {
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
                    Text(ArchitectureLayerBar.openQuestionsTitle(uncertainties.count))
                        .font(.title2.bold())
                    EpistemicBadge(.unknown)
                }
                ForEach(uncertainties.indices, id: \.self) { index in
                    Text(uncertainties[index])
                        .textSelection(.enabled)
                    if index < uncertainties.count - 1 {
                        Divider()
                    }
                }
            }
            .padding(DesignTokens.Spacing.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

#Preview {
    OpenQuestionsPanel(uncertainties: [
        "Is Persistence still read by any component now that session writes route through SessionStore?",
        "UserCache has no visible eviction policy.",
    ])
    .frame(width: 320, height: 400)
}
