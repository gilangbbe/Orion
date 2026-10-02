import SwiftUI

/// The practice loop for the selected concept, under the self-check note while grading isn't
/// calibrated (Docs/17 Decision 10).
struct PracticePane: View {
    let session: TeachingSession
    let repoRoot: URL
    let outputDirectory: URL
    let missingModels: [String]
    let recheckModels: () -> Void

    @State private var selectedEvidence: EvidenceDetail?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.xl) {
                    if !missingModels.isEmpty {
                        LocalModelSetupNotice(missing: missingModels, recheck: recheckModels)
                    }
                    if !TeachingSession.isCalibrated {
                        SelfCheckNote()
                    }
                    PracticePhaseView(
                        session: session, repoRoot: repoRoot, outputDirectory: outputDirectory,
                        showEvidence: showEvidence)
                }
                .padding(DesignTokens.Spacing.xxl)
                .frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            // Animated: it follows your own Check My Answer, never a pane being inserted, which is
            // what crashes macOS 27 (Docs/14, macOS 27 addendum).
            .onChange(of: isGraded) { _, graded in
                if graded {
                    withAnimation { proxy.scrollTo(PracticePhaseView.gradeAnchor, anchor: .top) }
                }
            }
        }
        .sheet(item: $selectedEvidence) { evidence in
            EvidenceView(evidence: evidence, source: CheckoutEvidenceSource(repoRoot: repoRoot))
        }
    }

    private var isGraded: Bool {
        if case .graded = session.phase { true } else { false }
    }

    private func showEvidence(_ evidence: EvidenceDetail) {
        selectedEvidence = evidence
    }
}
