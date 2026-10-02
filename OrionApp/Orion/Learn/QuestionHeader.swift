import SwiftUI

/// The question: which concept and depth, the explanation before it (while answering), and the
/// question itself.
struct QuestionHeader: View {
    let card: TeachingQuestionCard
    let showsExplanation: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
            Text("\(card.conceptLabel) · \(TeachingVocabulary.bandWord(card.band))")
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            if showsExplanation {
                LearnSection("Explain") {
                    MarkdownText(raw: card.explain)
                        .foregroundStyle(.secondary)
                }
            }
            LearnSection("Question") {
                MarkdownText(raw: card.prompt)
                    .font(showsExplanation ? .title3 : .headline)
                    .textSelection(.enabled)
            }
        }
    }
}
