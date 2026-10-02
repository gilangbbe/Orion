import OrionAgent
import SwiftUI

/// Ask (Docs/14 §4.6, Docs/15 §5, Docs/20 R4): sessions on the left, the selected conversation on
/// the right with the composer under it. A developer comes back to a session as reference, so the
/// list is grouped by what each is about -- General, then one group per component.
///
/// Docs/20 R4: the session list is a native `List(selection:)` in plain sections. Docs/14 hand-built
/// it to dodge `Section(isExpanded:)` in a sidebar list, which corrupted its layout when rows arrived
/// late; plain sections don't have that problem, and the native list brings keyboard navigation,
/// the system selection colour and type-select. Search moved to the toolbar.
///
/// `HSplitView` with a fixed-width list is kept (Docs/14 M8.7): a `NavigationSplitView` column here
/// could be dragged shut with no way back.
struct AskView: View {
    let repoRoot: URL
    let outputDirectory: URL
    @Bindable var history: AskHistory
    let diagnosticsSession: DiagnosticsSession
    /// For a `CONTRADICTED` claim's "Superseded — see Model Changes" link (Docs/16 §8 M5).
    let shellState: AppShellState

    @State private var search = ""
    /// Core AI bundles the answering role needs that aren't exported yet (Docs/18 M6).
    @State private var missingModels: [String] = []
    @State private var renamingSession: AskSessionRow?
    @State private var sessionPendingDelete: AskSessionRow?
    @State private var isConfirmingDelete = false

    var body: some View {
        HSplitView {
            AskSessionList(
                history: history, search: search, outputDirectory: outputDirectory,
                rename: rename, delete: confirmDelete)
                .frame(minWidth: 260, idealWidth: 260, maxWidth: 260, maxHeight: .infinity)
            AskConversationPane(
                repoRoot: repoRoot, outputDirectory: outputDirectory, history: history,
                diagnosticsSession: diagnosticsSession, shellState: shellState,
                missingModels: missingModels, recheckModels: checkModels)
                .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
        }
        .searchable(text: $search, placement: .toolbar, prompt: "Search Sessions")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("New Session", systemImage: "square.and.pencil", action: startGeneralSession)
                    .help("Start a new general session")
            }
        }
        .task {
            checkModels()
            await history.refresh(outputDirectory: outputDirectory)
        }
        .sheet(item: $renamingSession) { session in
            RenameSessionSheet(session: session, onSave: { title in save(title, for: session) })
        }
        // Docs/15 §4.7: hard to reverse, so it confirms, naming what survives.
        .alert(
            "Delete “\(sessionPendingDelete?.title ?? "")”?", isPresented: $isConfirmingDelete,
            presenting: sessionPendingDelete
        ) { session in
            Button("Delete", role: .destructive) { delete(session) }
        } message: { session in
            Text("This removes the session and its \(session.turnCount) \(session.turnCount == 1 ? "turn" : "turns"). The investigations behind its answers are kept.")
        }
    }

    private func checkModels() {
        missingModels = CoreAIModelLocator.missingVariants(for: .default, roles: [.answering])
    }

    private func startGeneralSession() {
        Task { await history.startSession(forGroupNamed: "General", componentId: nil, outputDirectory: outputDirectory) }
    }

    private func rename(_ session: AskSessionRow) {
        renamingSession = session
    }

    private func confirmDelete(_ session: AskSessionRow) {
        sessionPendingDelete = session
        isConfirmingDelete = true
    }

    private func save(_ title: String, for session: AskSessionRow) {
        Task { await history.rename(session.id, title: title, outputDirectory: outputDirectory) }
    }

    private func delete(_ session: AskSessionRow) {
        Task { await history.delete(session.id, outputDirectory: outputDirectory) }
    }
}
