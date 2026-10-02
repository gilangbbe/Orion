import SwiftUI

/// One Orion window (Docs/20 R1): its own `RepositoryWindow`, shown as welcome, progress, the
/// repository, or an error. `.task(id:)` on the session's state is what drives `idle -> opening ->
/// analyzing -> ready` (Docs/13 M2). The model is published to the menu bar through
/// `focusedSceneValue`, so File, View and Repository act on the window in front.
struct ContentView: View {
    @State private var window: RepositoryWindow

    init(recents: RecentRepositoriesModel) {
        _window = State(initialValue: RepositoryWindow(recents: recents))
    }

    var body: some View {
        WindowStateView(window: window)
            .frame(minWidth: 820, minHeight: 520)
            .focusedSceneValue(\.repositoryWindow, window)
            .fileImporter(isPresented: $window.isPickingFolder, allowedContentTypes: [.folder], onCompletion: openPicked)
            .sheet(isPresented: $window.isCloning) {
                CloneRepositorySheet(onClone: window.clone)
            }
            .sheet(isPresented: $window.isBuildingModel) {
                if let summary = window.summary {
                    BuildArchitectureModelSheet(
                        repoRoot: summary.repoRoot, outputDirectory: summary.outputDirectory, session: window.semantic)
                }
            }
            .task(id: window.session.state) { await window.sessionStateChanged() }
            .onChange(of: window.semantic.state) { _, state in
                guard case .completed = state else { return }
                Task { await window.architectureModelChanged() }
            }
            #if DEBUG
            .task { await LaunchEnvironment.apply(to: window) }
            #endif
    }

    private func openPicked(_ result: Result<URL, any Error>) {
        if case .success(let url) = result {
            window.openFolder(url)
        }
    }
}

#Preview {
    ContentView(recents: RecentRepositoriesModel())
}
