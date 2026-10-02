import SwiftUI

/// The inspector beside Architecture: the selected component, the open questions, or a prompt to
/// pick something. Its hand-offs reach into the window: "Ask About This" switches to Ask and
/// resumes or scopes a session (Docs/15 §5 M6), "Superseded — see Model Changes" opens the
/// revision that reversed a claim (Docs/16 §8 M5).
struct ArchitectureInspector: View {
    let window: RepositoryWindow
    let shell: AppShellState
    let summary: RepositorySummary

    var body: some View {
        switch shell.inspectorContent {
        case .node(let node, let layer):
            // `.id`: a new component is a new view, so its `.task` loads it (Docs/14 §8 M8.5 item 4).
            ComponentDetailView(
                outputDirectory: summary.outputDirectory, node: node, layer: layer,
                evidenceSource: CheckoutEvidenceSource(repoRoot: summary.repoRoot),
                onAskAbout: askAbout, onShowRevision: showRevision)
            .id(node.id)
        case .openQuestions(let uncertainties):
            OpenQuestionsPanel(uncertainties: uncertainties)
        case nil:
            ContentUnavailableView(
                "No Selection", systemImage: "sidebar.trailing",
                description: Text("Select a component to see its purpose, members and evidence."))
        }
    }

    private func askAbout(_ detail: ComponentDetail) {
        shell.destination = .ask
        let componentId = detail.isStructural ? nil : detail.id
        let history = window.askHistory
        Task {
            await history.askAbout(detail.name, componentId: componentId, outputDirectory: summary.outputDirectory)
        }
    }

    private func showRevision(_ revisionId: String) {
        shell.focusedModelChangeRevisionId = revisionId
        shell.destination = .changes
    }
}
