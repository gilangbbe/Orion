import OrionCodeIntel
import SwiftUI

/// Docs/08's "confidence" bullet -- a separate axis from `EpistemicBadge`'s epistemic type
/// (Docs/04's FACT/INTERPRETATION/... vocabulary answers "what kind of knowledge is this,"
/// `ConfidenceTier` answers "how sure are we"). Shown alongside `EpistemicBadge` wherever a
/// component, dependency, or claim carries a confidence tier. `color(forTier:)` is `static` so
/// `ArchitectureOverviewView`'s node/edge coloring can share the exact same mapping rather than
/// drifting from this badge's own colors.
struct ConfidenceBadge: View {
    let tier: String

    static func color(forTier tier: String) -> Color {
        switch tier.lowercased() {
        case "high": return .blue
        case "medium": return .yellow
        case "low": return .orange
        case "unresolved": return .gray
        default: return .secondary
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
        Text(tier.capitalized)
            .font(.caption2.bold())
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .foregroundStyle(Self.color(forTier: tier))
            .background(Self.color(forTier: tier).opacity(0.15))
            .clipShape(Capsule())
    }
}

#Preview {
    VStack(alignment: .leading, spacing: 8) {
        ForEach(["high", "medium", "low", "unresolved"], id: \.self) { ConfidenceBadge(tier: $0) }
    }
    .padding()
}
