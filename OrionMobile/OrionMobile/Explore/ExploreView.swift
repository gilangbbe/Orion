import OrionCore
import SwiftUI

/// Explore (Docs/19 M4, redesigned in M8): the open repository's architecture, from its snapshot.
///
/// A split view -- the HIG's "prefer split views in a regular environment" -- with the repository
/// overview and its components on the leading side and what's selected on the trailing side. On
/// iPhone it collapses to a stack that opens on the list. On iPad the map is shown until something
/// else is chosen.
struct ExploreView: View {
    let entry: LocalLibrary.Entry
    /// "Ask About This" on a component: the shell switches to Ask (Docs/19 M6).
    var onAskAbout: ((ComponentDetail) -> Void)? = nil

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var model: ArchitectureModel?
    @State private var loadError: String?
    @State private var selection: ExploreRoute?
    @State private var detailPath: [ExploreRoute] = []
    @State private var searchText = ""

    private var outputDirectory: URL { entry.databaseURL.deletingLastPathComponent() }

    var body: some View {
        NavigationSplitView {
            ExploreSidebar(
                entry: entry, model: model, loadError: loadError, selection: $selection,
                searchText: $searchText)
                .repositoryTitleMenu()
        } detail: {
            NavigationStack(path: $detailPath) {
                ExploreDetail(
                    route: selection, model: model, outputDirectory: outputDirectory, onAskAbout: onAskAbout,
                    open: open)
                    .navigationDestination(for: ExploreRoute.self) { route in
                        ExploreDetail(
                            route: route, model: model, outputDirectory: outputDirectory,
                            onAskAbout: onAskAbout, open: open)
                    }
            }
        }
        .task { await load() }
        .onChange(of: selection) { detailPath = [] }
    }

    private func open(_ route: ExploreRoute) {
        detailPath.append(route)
    }

    private func load() async {
        let outputDirectory = outputDirectory
        do {
            let loaded = try await Task.detached(priority: .userInitiated) {
                try ArchitectureModelLoader.load(outputDirectory: outputDirectory)
            }.value
            model = loaded
            loadError = nil
            if horizontalSizeClass == .regular, selection == nil, MapScreen.canDraw(loaded) {
                selection = .map
            }
        } catch {
            loadError = String(describing: error)
        }
    }

    static func nodesTitle(_ layer: ArchitectureLayer) -> String {
        if case .semantic = layer { return "Components" }
        return "Modules"
    }
}
