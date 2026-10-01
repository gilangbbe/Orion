import OrionCore
import SwiftUI

/// A question and its answer: the question in a trailing bubble, the answer full width with its
/// outcome label and, behind a disclosure, the code it cites.
struct AskTurnView: View {
    let turn: AskModel.Turn
    let onSelectEvidence: (EvidenceDetail) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
            if !turn.question.isEmpty {
                QuestionBubble(text: turn.question)
            }
            if let summary = turn.summary {
                MarkdownText(raw: summary.answerText)
                    .textSelection(.enabled)
                AskOutcomeLabel(summary: summary)
                SourcesDisclosure(evidence: summary.claims.flatMap(\.evidence), onSelect: onSelectEvidence)
            } else if let failure = turn.failure {
                StatusLabel(failure, systemImage: "exclamationmark.triangle", tint: .orange)
            }
        }
    }
}
