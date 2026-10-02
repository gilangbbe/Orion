import SwiftUI

/// An answer: its outcome, the text, its claims, and how it was routed.
struct AskAnswerView: View {
    let summary: AskResultSummary
    let showEvidence: (EvidenceDetail) -> Void
    let showRevision: (String) -> Void

    @State private var showsRouting = false

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
            AskOutcomeLabel(summary: summary)
            MarkdownText(raw: summary.answerText)
                .textSelection(.enabled)
            if !summary.isDeclined {
                if !summary.claims.isEmpty {
                    VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
                        ForEach(summary.claims) { claim in
                            AskClaimRow(claim: claim, showEvidence: showEvidence, showRevision: showRevision)
                        }
                    }
                    .padding(DesignTokens.Spacing.md)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: DesignTokens.Radius.control))
                } else if summary.claimCount > 0 || summary.droppedClaimCount > 0 {
                    // Recorded but not read back (best effort in AskRunner): still say so.
                    Text(Self.claimCountText(recorded: summary.claimCount, dropped: summary.droppedClaimCount))
                        .foregroundStyle(.secondary)
                }
                DisclosureGroup("How This Was Answered", isExpanded: $showsRouting) {
                    AskRoutingDetail(summary: summary)
                }
                .foregroundStyle(.secondary)
            }
        }
    }

    static func claimCountText(recorded: Int, dropped: Int) -> String {
        var text = "\(recorded) \(recorded == 1 ? "claim" : "claims") recorded"
        if dropped > 0 { text += ", \(dropped) dropped" }
        return text
    }
}
