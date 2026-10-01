import OrionCore
import SwiftUI

/// One concept's practice (Docs/19 M7, redesigned in M8): the question leads, the concept is a
/// short header above it, and the next action -- check the answer, or keep going -- sits in a bar
/// at the bottom, where the HIG notes controls are easiest to reach.
struct LearnPracticeView: View {
    @Bindable var model: LearnModel
    let conceptId: String
    @State private var selectedEvidence: EvidenceDetail?
    @FocusState private var answerFocused: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxl) {
                if let concept = model.concept {
                    ConceptHeader(concept: concept)
                }
                switch model.phase {
                case .picking:
                    DepthPicker(isBusy: model.isBusy) { band in Task { await model.question(band: band) } }
                case .drafting(let band):
                    WorkingRow(text: "Writing a \(TeachingVocabulary.bandWord(band).lowercased()) question on this iPhone…")
                case .questioning(let card):
                    QuestionCard(card: card, compact: false)
                    AnswerField(text: $model.answerDraft, focused: $answerFocused)
                case .grading(let card, let judged, let total):
                    QuestionCard(card: card, compact: true)
                    AnswerQuote(text: model.answerDraft)
                    GradingProgress(judged: judged, total: total)
                case .graded(let card, let grade):
                    QuestionCard(card: card, compact: true)
                    AnswerQuote(text: model.answerDraft)
                    GradeSummary(grade: grade) { selectedEvidence = $0 }
                    if let transfer = card.transferProblem, !transfer.isEmpty {
                        FollowUpPanel(text: transfer)
                    }
                }
                if let problem = model.problem {
                    ProblemBanner(problem: problem)
                }
            }
            .padding()
            .readableWidth()
        }
        .scrollDismissesKeyboard(.interactively)
        .safeAreaBar(edge: .bottom) {
            PracticeActionBar(model: model) { answerFocused = false }
                .readableWidth()
        }
        .navigationTitle(model.concept.map { TeachingVocabulary.kindWord($0.kind) } ?? "Practice")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $selectedEvidence) { evidence in
            EvidenceSheet(evidence: evidence, source: SnapshotEvidenceSource(outputDirectory: model.outputDirectory))
        }
        .onAppear {
            if model.conceptId != conceptId { model.open(conceptId: conceptId) }
        }
    }
}
