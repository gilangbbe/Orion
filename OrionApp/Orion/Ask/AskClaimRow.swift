import SwiftUI

/// A claim an answer made, and the code it rests on (Docs/13 M7).
struct AskClaimRow: View {
    let claim: AskClaimSummary
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
