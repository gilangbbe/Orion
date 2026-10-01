import OrionCore
import SwiftUI

/// Explore · Ask · Learn · Library. Explore, Ask and Learn work on the open repository; Ask
/// (Docs/19 M6) and Learn (M7) run on the on-device model.
///
/// Docs/19 M8: a tab bar on iPhone, convertible to a sidebar on iPad (`sidebarAdaptable`), that
/// minimizes while reading. The open repository can be switched from any tab's title menu
/// (`RepositoryTitleMenu`); Library manages them.
struct RootView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var library = LibraryModel.live()
    @State private var cloud = CloudSync()
    @State private var askRequest: AskRequest?
    /// `ORION_ASK_BENCH` at launch (Docs/19 M6): run the on-device Ask benchmark.
    @State private var benchAtLaunch = AskBench.launchRequest != nil
    /// `ORION_LEARN_BENCH` at launch (Docs/19 M7): run the on-device Learn benchmark.
    @State private var learnBenchAtLaunch = LearnBench.Request.atLaunch != nil
    @State private var tab: AppTab = .library

    var body: some View {
        TabView(selection: $tab) {
            Tab("Explore", systemImage: "map", value: AppTab.explore) {
                RepositoryScoped(library: library, showLibrary: showLibrary) { entry in
                    ExploreView(entry: entry, onAskAbout: askAbout)
                }
            }
            Tab("Ask", systemImage: "bubble.left.and.text.bubble.right", value: AppTab.ask) {
                RepositoryScoped(library: library, showLibrary: showLibrary) { entry in
                    AskView(entry: entry, request: $askRequest)
                }
            }
            Tab("Learn", systemImage: "graduationcap", value: AppTab.learn) {
                RepositoryScoped(library: library, showLibrary: showLibrary) { entry in
                    LearnView(entry: entry)
                }
            }
            Tab("Library", systemImage: "books.vertical", value: AppTab.library) {
                LibraryView(library: library, cloud: cloud, onOpen: showExplore)
            }
        }
        .tabViewStyle(.sidebarAdaptable)
        // Orion's brand colour for controls and links, tuned per appearance for contrast: white
        // text on the system blue of a prominent button failed the accessibility audit (Docs/19 M8).
        .tint(DesignTokens.tint)
        .tabBarMinimizeBehavior(.onScrollDown)
        .environment(library)
        .environment(\.showLibrary, showLibrary)
        .sheet(isPresented: $benchAtLaunch) {
            if let entry = library.selected, let request = AskBench.launchRequest {
                AskBenchView(entry: entry, ids: request.ids, forcedDepth: request.depth)
            }
        }
        .sheet(isPresented: $learnBenchAtLaunch) {
            if let entry = library.selected, let request = LearnBench.Request.atLaunch {
                LearnBenchView(entry: entry, request: request, autostart: true)
            }
        }
        .task { await start() }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task { await refresh() }
        }
    }

    private func start() async {
        library.refresh()
        let probing = ProcessInfo.processInfo.environment["FM_PROBE_AUTORUN"] == "1"
        if library.selected != nil, !probing { tab = .explore }
        await library.importInbox()
        await cloud.start(library: library)
    }

    private func refresh() async {
        await library.importInbox()
        await cloud.refresh()
    }

    /// "Ask About This" on a component: switch to Ask, scoped to it (Docs/19 M6).
    private func askAbout(_ detail: ComponentDetail) {
        askRequest = AskRequest(componentId: detail.isStructural ? nil : detail.id, componentName: detail.name)
        tab = .ask
    }

    private func showExplore() { tab = .explore }
    private func showLibrary() { tab = .library }
}
