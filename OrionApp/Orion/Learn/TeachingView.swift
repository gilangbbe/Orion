import OrionAgent
import SwiftUI

/// Learn (Docs/05 Stage 7, Docs/17 §11, Docs/20 R5): concepts on the left, ranked by
/// `TeachingPlanner` with how well you know each; on the right, the practice loop for the selected
/// one -- Explain → Question → Your Answer → Evaluation → Correction → Transfer. The evaluation is
/// the decomposed, point-by-point grade, your own words quoted back (Docs/17 §2.1, H7).
///
/// Docs/20 R5: a native concept list, search and Practise Next in the toolbar, standard buttons
/// instead of Liquid Glass in the content layer (HIG, Materials), a growing text field for the
/// answer. Same fixed-width `HSplitView` as Ask, for the same reason.
struct TeachingView: View {
    let session: TeachingSession
    let repoRoot: URL
    let outputDirectory: URL

    @State private var search = ""
    /// Core AI bundles the drafting and judging roles need that aren't exported yet (Docs/18 M6).
    @State private var missingModels: [String] = []

    var body: some View {
        HSplitView {
            ConceptList(session: session, search: search, outputDirectory: outputDirectory)
                .frame(minWidth: 280, idealWidth: 280, maxWidth: 280, maxHeight: .infinity)
            PracticePane(
                session: session, repoRoot: repoRoot, outputDirectory: outputDirectory,
                missingModels: missingModels, recheckModels: checkModels)
                .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
        }
        .searchable(text: $search, placement: .toolbar, prompt: "Search Concepts")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Practise Next", systemImage: "forward", action: practiseNext)
                    .help(nextHelp)
                    .disabled(session.concepts.isEmpty || session.isGenerating)
            }
        }
        .task {
            checkModels()
            await session.refresh(outputDirectory: outputDirectory)
        }
    }

    private var nextHelp: String {
        if let next = session.concepts.first {
            "Practise the suggested concept: \(next.label)"
        } else {
            "Practise the suggested concept"
        }
    }

    private func practiseNext() {
        Task { await session.startNext(repoRoot: repoRoot, outputDirectory: outputDirectory) }
    }

    private func checkModels() {
        missingModels = CoreAIModelLocator.missingVariants(for: .default, roles: [.drafting, .judging])
    }
}
