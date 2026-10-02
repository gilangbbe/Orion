import SwiftUI

/// After a grade: the transfer problem one level up, another question here, or the next concept.
struct NextStepPanel: View {
    let card: TeachingQuestionCard
    let session: TeachingSession
    let repoRoot: URL
    let outputDirectory: URL

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
            if let transfer = card.transferProblem, !transfer.isEmpty {
                LearnSection("Transfer Problem") {
                    MarkdownText(raw: transfer)
                        .textSelection(.enabled)
                }
            } else {
                Text("Keep Going")
                    .font(.headline)
            }
            HStack(spacing: DesignTokens.Spacing.sm) {
                if card.transferProblem?.isEmpty == false, card.band < 3 {
                    Button("Try It, One Level Up", action: tryTransfer)
                        .buttonStyle(.borderedProminent)
                }
                Button("Another Question Here", action: anotherQuestion)
                Button("Next Concept", action: nextConcept)
            }
            .controlSize(.large)
            .disabled(session.isGenerating)
        }
        .padding(DesignTokens.Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: DesignTokens.Radius.panel))
    }

    private func tryTransfer() {
        Task { await session.tryTransfer(repoRoot: repoRoot, outputDirectory: outputDirectory) }
    }

    private func anotherQuestion() {
        Task { await session.anotherQuestion(repoRoot: repoRoot, outputDirectory: outputDirectory) }
    }

    private func nextConcept() {
        Task { await session.startNext(repoRoot: repoRoot, outputDirectory: outputDirectory) }
    }
}
