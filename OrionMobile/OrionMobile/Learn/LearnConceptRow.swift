import SwiftUI

/// A concept in the list: its label, mastery, attempts and any misconception still open.
struct LearnConceptRow: View {
    let row: TeachingConceptRow

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            Text(row.label)
                .scaledLineLimit(3)
            HStack(spacing: DesignTokens.Spacing.sm) {
                MasteryMeter(pMastered: row.pMastered, band: row.confidenceBand)
                if row.hasOpenMisconception {
                    Label("Misconception", systemImage: "exclamationmark.triangle.fill")
                        .labelStyle(.iconOnly)
                        .font(.footnote)
                        .foregroundStyle(DesignTokens.contradicted)
                }
                Spacer(minLength: 0)
                if row.attempts > 0 {
                    Text("^[\(row.attempts) attempt](inflect: true)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}
