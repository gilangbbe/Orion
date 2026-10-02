import SwiftUI

/// A concept: its name, how well you know it, and what kind of thing it is.
struct ConceptRow: View {
    let row: TeachingConceptRow

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Spacing.xs) {
                Text(row.label)
                    .lineLimit(2)
                Spacer(minLength: 0)
                if row.hasOpenMisconception {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(DesignTokens.contradicted)
                        .accessibilityLabel("Open misconception")
                        .help("You've shown a misconception here")
                }
            }
            HStack(spacing: DesignTokens.Spacing.sm) {
                MasteryMeter(pMastered: row.pMastered, band: row.confidenceBand)
                Text(TeachingVocabulary.kindWord(row.kind))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}
