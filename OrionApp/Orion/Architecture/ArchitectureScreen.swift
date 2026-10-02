import SwiftUI

/// Architecture (Docs/13 M4, Docs/14 §4.4, Docs/20 R3): which layer is showing, then the diagram
/// or a sortable table, with the selected component in the native inspector. The toolbar carries
/// Build Architecture Model, the Diagram/Table switch -- "consider a segmented control for view
/// switching in a toolbar" (HIG, Segmented controls, macOS) -- and the inspector toggle at the
/// trailing edge, where the HIG puts "nearby inspectors".
///
/// Reloads whenever the investigation's state changes, so finishing Build Architecture Model
/// upgrades the view from structural to semantic with no other wiring.
struct ArchitectureScreen: View {
    let window: RepositoryWindow
    @Bindable var shell: AppShellState
    let summary: RepositorySummary

    @State private var model: ArchitectureModel?
    @State private var loadError: String?

    var body: some View {
        ArchitectureContent(model: model, loadError: loadError, shell: shell)
            .inspector(isPresented: $shell.isInspectorPresented) {
                ArchitectureInspector(window: window, shell: shell, summary: summary)
                    .inspectorColumnWidth(min: 300, ideal: 360, max: 560)
            }
            .toolbar {
                ArchitectureToolbar(window: window, shell: shell)
            }
            .task(id: window.semantic.state) { await reload() }
    }

    private func reload() async {
        let outputDirectory = summary.outputDirectory
        do {
            model = try await Task.detached(priority: .userInitiated) {
                try ArchitectureModelLoader.load(outputDirectory: outputDirectory)
            }.value
            loadError = nil
        } catch {
            loadError = String(describing: error)
        }
    }
}
