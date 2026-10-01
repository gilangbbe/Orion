import SwiftUI

/// One claim: the statement, its status, a link to the change that reversed it, and its sources
/// behind a disclosure.
struct ClaimRow: View {
    let claim: ComponentClaimDetail
    let open: (ExploreRoute) -> Void
    let onSelectEvidence: (EvidenceDetail) -> Void
    @State private var showsSources = false

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            MarkdownText(raw: claim.statement)
                .textSelection(.enabled)
            AdaptiveStack {
                EpistemicBadge(rawValue: claim.claimType)
                ConfidenceNote(tier: claim.confidence)
            }
            if let revisionId = claim.reversedByRevisionId {
                // A borderless button, not a NavigationLink: a link would make the whole row
                // navigate, over the sources disclosure.
                Button("Superseded — see Model Changes", systemImage: "clock.arrow.circlepath") {
                    open(.changes(focusRevisionId: revisionId))
                }
                .font(.subheadline)
                .buttonStyle(.borderless)
            }
            if !claim.evidence.isEmpty {
                DisclosureGroup(isExpanded: $showsSources) {
                    ForEach(claim.evidence) { evidence in
                        Button(evidence.anchor) { onSelectEvidence(evidence) }
                            .font(.footnote.monospaced())
                            .buttonStyle(.borderless)
                            .lineLimit(2)
                            .truncationMode(.middle)
                    }
                } label: {
                    Text("^[\(claim.evidence.count) source](inflect: true)")
                        .font(.subheadline)
                }
            }
        }
        .padding(.vertical, DesignTokens.Spacing.xs)
    }
}
