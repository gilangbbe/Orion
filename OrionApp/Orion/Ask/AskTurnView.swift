import SwiftUI

/// One question and its answer: how far to trust it (including Docs/12 Risk #5's "not
/// independently checked" and Docs/15 §7's decline), the answer, the claims with their code, and
/// the routing behind "How This Was Answered".
struct AskTurnView: View {
    let turn: AskTurnRow
    let repoRoot: URL
    let shellState: AppShellState

    @State private var selectedEvidence: EvidenceDetail?

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
            Label {
                Text(turn.question)
                    .font(.title3.weight(.semibold))
                    .textSelection(.enabled)
            } icon: {
                Image(systemName: "person.crop.circle")
                    .foregroundStyle(.secondary)
            }
            switch turn.outcome {
            case nil:
                Label {
                    Text("Thinking… The first local question also loads the Core AI model, which takes a few seconds.")
                        .foregroundStyle(.secondary)
                } icon: {
                    ProgressView().controlSize(.small)
                }
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
            case .answered(let summary):
                AskAnswerView(summary: summary, showEvidence: showEvidence, showRevision: showRevision)
            }
        }
        .sheet(item: $selectedEvidence) { evidence in
            EvidenceView(evidence: evidence, source: CheckoutEvidenceSource(repoRoot: repoRoot))
        }
    }

    private func showEvidence(_ evidence: EvidenceDetail) {
        selectedEvidence = evidence
    }

    private func showRevision(_ revisionId: String) {
        shellState.focusedModelChangeRevisionId = revisionId
        shellState.destination = .changes
    }
}
