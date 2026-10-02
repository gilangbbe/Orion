import SwiftUI

/// The grade, point by point, then the correction, how mastery moved, and where to go next.
struct GradedView: View {
    let card: TeachingQuestionCard
    let grade: TeachingGradeCard
    let session: TeachingSession
    let repoRoot: URL
    let outputDirectory: URL
    let showEvidence: (EvidenceDetail) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xl) {
            QuestionHeader(card: card, showsExplanation: false)
            AnswerQuote(text: session.answerDraft)
            GroupBox {
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
                    TeachingVerdictHeader(grade: grade)
                    Divider()
                    TeachingCriterionChecklist(rows: grade.criteria, onOpenEvidence: showEvidence)
                    if grade.disputed {
                        Label("The overall score and a same-idea check disagreed. Re-read the reference answer below.", systemImage: "questionmark.circle")
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(DesignTokens.Spacing.xs)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if !grade.misconceptionsDetected.isEmpty || !grade.misconceptionsCleared.isEmpty {
                TeachingMisconceptionOutcome(grade: grade)
            }
            LearnSection("Correction") {
                MarkdownText(raw: grade.correction)
                    .textSelection(.enabled)
            }
            if let before = grade.masteryBefore, let after = grade.masteryAfter, let band = grade.bandAfter {
                MasteryChangeRow(before: before, after: after, band: band)
            }
            NextStepPanel(card: card, session: session, repoRoot: repoRoot, outputDirectory: outputDirectory)
            if let error = session.generateError {
                PracticeErrorView(message: error)
            }
        }
    }
}
