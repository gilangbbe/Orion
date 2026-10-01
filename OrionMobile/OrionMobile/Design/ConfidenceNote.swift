import SwiftUI

/// A confidence tier, shown only when it's worth a look: "Medium confidence", "Low confidence",
/// "Unresolved". High confidence -- nearly every row in a real snapshot -- shows nothing, where the
/// old badge-on-every-row was noise (Docs/19 M8). Signal bars carry the level beside the word, so
/// colour is never the only cue.
struct ConfidenceNote: View {
    let tier: String

    static func isWorthShowing(_ tier: String?) -> Bool {
        guard let tier else { return false }
        return tier.lowercased() != "high"
    }

    var body: some View {
        if Self.isWorthShowing(tier) {
            Label {
                Text(Self.text(tier))
            } icon: {
                Image(systemName: "cellularbars", variableValue: Self.level(tier))
            }
            .font(.footnote)
            .foregroundStyle(ConfidenceBadge.color(forTier: tier))
        }
    }

    static func text(_ tier: String) -> String {
        tier.lowercased() == "unresolved" ? "Unresolved" : "\(tier.capitalized) confidence"
    }

    static func level(_ tier: String) -> Double {
        Double(ConfidenceBadge.barsFilled(forTier: tier)) / 3
    }
}
