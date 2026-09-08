import OrionCodeIntel
import SwiftUI

/// Docs/14_phase4_5_ui_ux_redesign.md §3 / M0: confidence renders as an OUTLINED capsule with a
/// 3-bar signal meter, never a filled capsule -- `EpistemicBadge` already owns the filled-capsule
/// look for "what kind of knowledge is this," so confidence ("how sure are we," a genuinely
/// independent axis, Docs/08) needs to be distinguishable by *shape*, not only by the two badges
/// happening to use different hues. This is a real, not hypothetical, problem: `EpistemicTag.unknown`
/// and `ConfidenceTier.unresolved` are both gray, and the two badges sit side by side constantly (a
/// component, a claim) -- two identical-looking filled gray pills told a viewer nothing extra. An
/// outlined pill next to a filled one reads as two different kinds of information before either
/// color or label is even read, which is the actual point (WCAG's "use of color" -- never the only
/// channel that carries meaning).
struct ConfidenceBadge: View {
    let tier: String

    static func color(forTier tier: String) -> Color {
        switch tier.lowercased() {
        case "high": return DesignTokens.confidenceHigh
        case "medium": return DesignTokens.confidenceMedium
        case "low": return DesignTokens.confidenceLow
        case "unresolved": return DesignTokens.confidenceUnresolved
        default: return .secondary
        }
    }

    /// How many of the meter's 3 bars are filled for a given tier. An unrecognized tier reads as
    /// 0 -- the same as `unresolved` -- rather than guessing; an unknown string is never more
    /// confident than "unresolved."
    static func barsFilled(forTier tier: String) -> Int {
        switch tier.lowercased() {
        case "high": return 3
        case "medium": return 2
        case "low": return 1
        default: return 0
        }
    }

    /// `ClaimRecord.confidence` is stored as `ConfidenceTier.score` (0.9/0.6/0.3/0.1), not the
    /// tier label itself -- unlike `ComponentRecord`/`ComponentRelationshipRecord`, which keep
    /// both. Reverses that exact mapping so a claim's confidence can be shown with the same
    /// vocabulary as everything else that already carries a tier string directly. Shared here
    /// (not duplicated per call site -- `ComponentDetailLoader` and `AskRunner` both need it).
    static func tierLabel(forScore score: Double) -> String {
        ConfidenceTier.allCases.first { $0.score == score }?.rawValue
            ?? String(format: "%.2f", score)
    }

    var body: some View {
        let color = Self.color(forTier: tier)
        Label {
            Text(tier.capitalized)
        } icon: {
            SignalBars(filled: Self.barsFilled(forTier: tier), color: color)
        }
        .font(.caption2.bold())
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .foregroundStyle(color)
        .background(Capsule().strokeBorder(color, lineWidth: 1.3))
    }
}

/// The signal meter itself -- ascending bar heights, filled from the left. An unfilled bar is
/// always drawn in a neutral secondary tone, never a faded version of the tier's own hue, which
/// would just read as a lighter copy of the same badge instead of a genuinely "off" bar.
private struct SignalBars: View {
    let filled: Int
    let color: Color

    var body: some View {
        HStack(alignment: .bottom, spacing: 1.5) {
            bar(height: 5, isOn: filled >= 1)
            bar(height: 7, isOn: filled >= 2)
            bar(height: 9, isOn: filled >= 3)
        }
    }

    private func bar(height: CGFloat, isOn: Bool) -> some View {
        RoundedRectangle(cornerRadius: 0.75)
            .fill(isOn ? color : Color.secondary.opacity(0.35))
            .frame(width: 3, height: height)
    }
}

#Preview {
    VStack(alignment: .leading, spacing: 8) {
        ForEach(["high", "medium", "low", "unresolved"], id: \.self) { ConfidenceBadge(tier: $0) }
    }
    .padding()
}
