import SwiftUI

/// The question, and where you answer it.
struct AnsweringView: View {
    let card: TeachingQuestionCard
    @Bindable var session: TeachingSession
    let repoRoot: URL
    let outputDirectory: URL

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xl) {
            QuestionHeader(card: card, showsExplanation: true)
            LearnSection("Your Answer") {
                TextField("Explain it in your own words", text: $session.answerDraft, axis: .vertical)
                    .lineLimit(6...)
                    .textFieldStyle(.roundedBorder)
                Text("You'll get a point-by-point breakdown of your answer, not just a score.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: DesignTokens.Spacing.sm) {
                Button("Check My Answer", action: submit)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(session.answerDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Different Question", action: differentQuestion)
                    .disabled(session.isGenerating)
            }
            .controlSize(.large)
            if let error = session.generateError {
                PracticeErrorView(message: error)
            }
        }
    }

    private func submit() {
        Task { await session.submit(repoRoot: repoRoot, outputDirectory: outputDirectory) }
    }

    private func differentQuestion() {
        let band = card.band
        Task { await session.getQuestion(band: band, repoRoot: repoRoot, outputDirectory: outputDirectory) }
    }
}
