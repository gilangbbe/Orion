import OrionCodeIntel
import SwiftUI

/// Docs/17_phase7_teaching_mode.md §2.5/§8.2/§11: a developer's mastery of one concept is a
/// low-precision probability, shown as a coarse band — never a false-precise percentage. This is
/// the one shared way it renders (rail row, concept card, post-grade "mastery moved" line), so
/// the band→colour mapping lives in exactly one place, the same discipline `EpistemicBadge` /
/// `ConfidenceBadge` already follow.
///
/// A native `Gauge` with `.accessoryLinearCapacity` (Apple's compact leading-to-trailing capacity
/// bar) carries the rough magnitude; the band word carries the meaning. `p_mastered` fills the
/// bar but is deliberately not printed as a number.
struct MasteryMeter: View {
    let pMastered: Double
    let band: String
    /// `true` in the compact rail row (bar only, plus the band as an accessibility label);
    /// `false` on the concept card (bar + the band word beside it).
    var showsLabel = true

    static func color(forBand band: String) -> Color {
        switch band.lowercased() {
        case KnowledgeConfidenceBand.solid.rawValue: return DesignTokens.fact
        case KnowledgeConfidenceBand.developing.rawValue: return DesignTokens.confidenceMedium
        case KnowledgeConfidenceBand.shaky.rawValue: return DesignTokens.confidenceLow
        default: return DesignTokens.confidenceUnresolved  // "new" / unrecognised
        }
    }

    static func label(forBand band: String) -> String {
        switch band.lowercased() {
        case KnowledgeConfidenceBand.solid.rawValue: return "Solid"
        case KnowledgeConfidenceBand.developing.rawValue: return "Developing"
        case KnowledgeConfidenceBand.shaky.rawValue: return "Shaky"
        default: return "New"
        }
    }

    var body: some View {
        let color = Self.color(forBand: band)
        let word = Self.label(forBand: band)
        HStack(spacing: 6) {
            Gauge(value: pMastered.clamped(to: 0...1)) { EmptyView() }
                .gaugeStyle(.accessoryLinearCapacity)
                .tint(color)
                .frame(width: showsLabel ? 56 : 44)
                .accessibilityLabel("Mastery")
                .accessibilityValue(word)
            if showsLabel {
                Text(word)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(color)
            }
        }
    }
}

extension Comparable {
    fileprivate func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

#Preview {
    VStack(alignment: .leading, spacing: 10) {
        MasteryMeter(pMastered: 0.15, band: "new")
        MasteryMeter(pMastered: 0.42, band: "shaky")
        MasteryMeter(pMastered: 0.7, band: "developing")
        MasteryMeter(pMastered: 0.93, band: "solid")
        MasteryMeter(pMastered: 0.5, band: "developing", showsLabel: false)
    }
    .padding()
}
