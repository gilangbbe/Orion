import SwiftUI

/// The selected destination's screen. Each adds its own toolbar items, which join the window's.
struct DestinationView: View {
    let window: RepositoryWindow
    let shell: AppShellState
    let summary: RepositorySummary

    var body: some View {
        switch shell.destination {
        case .overview:
            ArchitectureScreen(window: window, shell: shell, summary: summary)
        case .ask:
            AskView(
                repoRoot: summary.repoRoot, outputDirectory: summary.outputDirectory, history: window.askHistory,
                diagnosticsSession: window.diagnostics, shellState: shell)
        case .teaching:
            TeachingView(session: window.teaching, repoRoot: summary.repoRoot, outputDirectory: summary.outputDirectory)
        case .changes:
            ModelChangesView(
                outputDirectory: summary.outputDirectory, focusedRevisionId: shell.focusedModelChangeRevisionId)
        case .diagnostics:
            DiagnosticsView(session: window.diagnostics, semantic: window.semantic, summary: summary)
        }
    }
}
