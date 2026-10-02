import SwiftUI

/// A claim about the component: what kind of knowledge, how confident, the statement, and the
/// code it rests on, one link per line (Docs/14 §8 M8.6). A `CONTRADICTED` claim links to the
/// revision that reversed it (Docs/14 §2, Docs/16 §8 M5).
struct ComponentClaimRow: View {
    let claim: ComponentClaimDetail
    let showEvidence: (EvidenceDetail) -> Void
    let showRevision: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            HStack(spacing: DesignTokens.Spacing.sm) {
                EpistemicBadge(rawValue: claim.claimType)
                ConfidenceBadge(tier: claim.confidence)
            }
            MarkdownText(raw: claim.statement)
            if let revisionId = claim.reversedByRevisionId {
                Button("Superseded — see Model Changes", systemImage: "clock.arrow.circlepath") {
                    showRevision(revisionId)
                }
                .buttonStyle(.link)
            }
            ForEach(claim.evidence) { evidence in
                EvidenceLinkButton(title: evidence.anchor, evidence: evidence, show: showEvidence)
            }
        }
    }
}
