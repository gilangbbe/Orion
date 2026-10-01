import SwiftUI

/// The graded answer: the verdict, each point, misconceptions, the correction, and the self-check
/// reminder.
struct GradeSummary: View {
    let grade: TeachingGradeCard
    let onSelectEvidence: (EvidenceDetail) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xl) {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
                TeachingVerdictHeader(grade: grade)
                Divider()
                TeachingCriterionChecklist(rows: grade.criteria, onOpenEvidence: onSelectEvidence)
            }
            .padding(DesignTokens.Spacing.lg)
            .background(.fill.quaternary, in: .rect(cornerRadius: DesignTokens.Radius.window))

            if !grade.misconceptionsDetected.isEmpty || !grade.misconceptionsCleared.isEmpty {
                TeachingMisconceptionOutcome(grade: grade)
            }
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
                Text("Correction")
                    .font(.subheadline.bold())
                    .foregroundStyle(.secondary)
                MarkdownText(raw: grade.correction)
            }
            if !LearnModel.isCalibrated {
                SelfCheckNote()
            }
        }
    }
}
