import OrionCore
import SwiftUI

/// The question: its depth, who wrote it, its setup and the question itself. A device-written
/// question carries a caution -- the verifier checks its citations, not its truth (Docs/19 M7).
struct QuestionCard: View {
    let card: TeachingQuestionCard
    let compact: Bool

    private var writtenOnDevice: Bool { card.generatedBy == TeachingQuestionSource.device.rawValue }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
            HStack {
                Text(TeachingVocabulary.bandWord(card.band))
                    .font(.subheadline.bold())
                    .foregroundStyle(.secondary)
                Spacer()
                Label(
                    writtenOnDevice ? "Written on this iPhone" : "From your Mac",
                    systemImage: writtenOnDevice ? "iphone" : "laptopcomputer")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            if !compact {
                MarkdownText(raw: card.explain)
                    .foregroundStyle(.secondary)
            }
            MarkdownText(raw: card.prompt)
                .font(compact ? .headline : .title3)
                .bold()
            if !compact, writtenOnDevice {
                Label("Written by the on-device model. Its points can be wrong, so check them against the evidence.", systemImage: "exclamationmark.bubble")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
