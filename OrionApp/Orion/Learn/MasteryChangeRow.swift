import SwiftUI

/// How this answer moved your mastery of the concept.
struct MasteryChangeRow: View {
    let before: Double
    let after: Double
    let band: String

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            Text("Mastery")
                .font(.headline)
            MasteryMeter(pMastered: before, band: band, showsLabel: false)
                .opacity(0.5)
            Image(systemName: "arrow.right")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            MasteryMeter(pMastered: after, band: band, showsLabel: true)
        }
        .accessibilityElement(children: .combine)
    }
}
