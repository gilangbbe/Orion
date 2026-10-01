import SwiftUI

/// The planner's pick, with a prominent way to start.
struct UpNextCard: View {
    let concept: TeachingConceptRow
    let start: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                    Text(TeachingVocabulary.kindWord(concept.kind))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text(concept.label)
                        .font(.headline)
                        .scaledLineLimit(3)
                }
                MasteryMeter(pMastered: concept.pMastered, band: concept.confidenceBand)
            }
            .accessibilityElement(children: .combine)
            // Solid, not glass: an action inside content, where glass dilutes the tint under the
            // white label below the contrast the audit expects (Docs/19 M8). Glass is for the
            // floating bars.
            Button(action: start) {
                Label("Practise", systemImage: "play.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .accessibilityIdentifier("learn.practiseNext")
        }
        .padding(.vertical, DesignTokens.Spacing.xs)
    }
}
