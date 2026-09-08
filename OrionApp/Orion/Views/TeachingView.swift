import SwiftUI

/// Docs/14_phase4_5_ui_ux_redesign.md §4.8/§8 M7: Docs/05 Stage 7's loop (Explain -> Question ->
/// Developer answer -> Evaluation -> Correction -> Transfer problem), rendered as one scrolling
/// column with each stage labeled by a small eyebrow so the pedagogical structure is visible
/// rather than implied. Backed by a fixed `TeachingSample` (Docs/14 §7 Decision 3) -- there is no
/// real evaluation logic behind "Submit Answer" yet, only the shape this screen needs to support
/// once one exists.
struct TeachingView: View {
    private enum Step {
        case answering
        case evaluated
    }

    let sample: TeachingSample

    @State private var step: Step = .answering
    @State private var answerText = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    eyebrow("Explain")
                    Text(sample.explain)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 6) {
                    eyebrow("Question")
                    Text(sample.question)
                        .font(.title3.weight(.semibold))
                }

                switch step {
                case .answering:
                    answeringSection
                case .evaluated:
                    evaluatedSection
                }
            }
            .padding(24)
            .frame(maxWidth: 560, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    private var answeringSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            eyebrow("Your Answer")
            TextEditor(text: $answerText)
                .font(.callout)
                .scrollContentBackground(.hidden)
                .padding(8)
                .frame(height: 110)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.control))
                .overlay(
                    RoundedRectangle(cornerRadius: DesignTokens.Radius.control)
                        .strokeBorder(Color(nsColor: .separatorColor))
                )
            Button("Submit Answer") { step = .evaluated }
                .buttonStyle(.glassProminent)
                .disabled(answerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private var evaluatedSection: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                eyebrow("Your Answer")
                Text("“\(answerText)”")
                    .font(.callout)
                    .italic()
                    .foregroundStyle(.secondary)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.control))
            }

            VStack(alignment: .leading, spacing: 6) {
                Label("Evaluation — \(sample.evaluationVerdict)", systemImage: "questionmark.circle")
                    .font(.caption.bold())
                    .foregroundStyle(DesignTokens.confidenceMedium)
                Text(sample.evaluationBody)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 6) {
                eyebrow("Correction")
                Text(sample.correction)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 10) {
                eyebrow("Transfer Problem")
                Text(sample.transferProblem)
                    .font(.callout)
                HStack(spacing: 8) {
                    Button("Try Another") { reset() }
                        .buttonStyle(.glass)
                    Button("Done for Now") { reset() }
                        .buttonStyle(.glassProminent)
                }
            }
            .padding(14)
            .background(DesignTokens.accent.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.panel))
        }
    }

    private func eyebrow(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.caption2.bold())
            .foregroundStyle(DesignTokens.accent)
            .tracking(0.5)
    }

    private func reset() {
        step = .answering
        answerText = ""
    }
}

#Preview {
    TeachingView(sample: .tokenManagerVsSessionManager)
        .frame(width: 620, height: 560)
}
