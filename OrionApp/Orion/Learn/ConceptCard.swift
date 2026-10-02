import SwiftUI

/// A picked concept: what it is, how you've done, any misconception you hold about it, and the
/// depth of question to ask for.
struct ConceptCard: View {
    let row: TeachingConceptRow
    let session: TeachingSession
    let repoRoot: URL
    let outputDirectory: URL

    @State private var band = 1

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xl) {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
                Text(TeachingVocabulary.kindWord(row.kind))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text(row.label)
                    // A claim's label is a whole sentence; a title size only suits a name.
                    .font(row.label.count > 80 ? .title3 : .title2.bold())
                    .textSelection(.enabled)
                HStack(spacing: DesignTokens.Spacing.md) {
                    MasteryMeter(pMastered: row.pMastered, band: row.confidenceBand, showsLabel: true)
                    if row.attempts > 0 {
                        Text(Self.attemptsText(row))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            if !row.openMisconceptions.isEmpty {
                MisconceptionPanel(statements: row.openMisconceptions)
            }
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
                Picker("Question depth", selection: $band) {
                    Text("Recall").tag(1)
                    Text("Comprehension").tag(2)
                    Text("Transfer").tag(3)
                }
                .pickerStyle(.segmented)
                .fixedSize()
                Text(Self.bandHint(band))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if session.isGenerating {
                WorkingLabel(text: band >= 3
                    ? "Writing a transfer question. This uses Claude and can take a minute or two."
                    : "Writing a question. The first one also loads the local Core AI model.")
            } else {
                Button("Get a Question", systemImage: "text.badge.plus", action: getQuestion)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            }
            if let error = session.generateError {
                PracticeErrorView(message: error)
            }
        }
        .task(id: row.id) { band = row.difficultyBand }
    }

    private func getQuestion() {
        let band = band
        Task { await session.getQuestion(band: band, repoRoot: repoRoot, outputDirectory: outputDirectory) }
    }

    static func bandHint(_ band: Int) -> String {
        switch band {
        case 1: "State or define what this is and does."
        case 2: "Explain how it relates to or differs from a neighbour."
        default: "What breaks if this changes? Uses Claude, which costs a little."
        }
    }

    static func attemptsText(_ row: TeachingConceptRow) -> String {
        var parts = [row.attempts == 1 ? "1 attempt" : "\(row.attempts) attempts"]
        if let verdict = row.lastVerdict {
            parts.append("last: \(verdict.replacing("-", with: " "))")
        }
        return parts.joined(separator: " · ")
    }
}
