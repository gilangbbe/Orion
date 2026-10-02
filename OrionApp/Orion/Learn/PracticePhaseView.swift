import SwiftUI

/// Where the loop is: nothing picked, a concept picked, answering, being graded, or graded.
struct PracticePhaseView: View {
    let session: TeachingSession
    let repoRoot: URL
    let outputDirectory: URL
    let showEvidence: (EvidenceDetail) -> Void

    static let gradeAnchor = "grade"

    var body: some View {
        switch session.phase {
        case .idle:
            ContentUnavailableView {
                Label("Practise a Concept", systemImage: "graduationcap")
            } description: {
                Text("Pick a concept on the left, or choose Practise Next to start the suggested one.")
            }
            .frame(minHeight: 320)
        case .picking(let conceptId):
            if let row = session.concepts.first(where: { $0.id == conceptId }) {
                ConceptCard(row: row, session: session, repoRoot: repoRoot, outputDirectory: outputDirectory)
            }
        case .questioning(let card):
            AnsweringView(card: card, session: session, repoRoot: repoRoot, outputDirectory: outputDirectory)
        case .grading(let card):
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xl) {
                QuestionHeader(card: card, showsExplanation: false)
                AnswerQuote(text: session.answerDraft)
                WorkingLabel(text: "Checking each point against the code. This runs the local model; a Comprehension or Transfer question can take a few minutes.")
            }
        case .graded(let card, let grade):
            GradedView(
                card: card, grade: grade, session: session, repoRoot: repoRoot, outputDirectory: outputDirectory,
                showEvidence: showEvidence)
                .id(Self.gradeAnchor)
        }
    }
}
