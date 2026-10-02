#if DEBUG
import Foundation

/// Launch hooks for checking the app without clicking through it (Docs/20 R7). Environment
/// variables, not arguments: AppKit treats a positional argument as a file to open.
///
/// - `ORION_OPEN_REPO=<path>`: open that repository in the first window.
/// - `ORION_DESTINATION=overview|ask|teaching|changes|diagnostics`: once it's ready, show that.
/// - `ORION_VIEW_MODE=Diagram|Table`, `ORION_INSPECT=<component name>|questions`: Architecture's
///   view and inspector.
/// - `ORION_SHOW=sync|build|clone`: open the Sync popover or a sheet.
/// - `ORION_SELECT=first`: select the first Ask session or Learn concept.
/// - `ORION_SYNC_PUBLISH` (Docs/19 M5): see `IPhoneSync.publishFromLaunchEnvironment`.
@MainActor
enum LaunchEnvironment {
    private static var applied = false

    static func apply(to window: RepositoryWindow) async {
        guard !applied else { return }
        applied = true
        await window.sync.publishFromLaunchEnvironment()
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["ORION_OPEN_REPO"], !path.isEmpty else {
            if environment["ORION_SHOW"] == "clone" { window.isCloning = true }
            return
        }
        window.openFolder(URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL)
        while window.summary == nil {
            if case .failed = window.session.state { return }
            try? await Task.sleep(for: .milliseconds(200))
        }
        if let raw = environment["ORION_DESTINATION"], let destination = Destination(rawValue: raw) {
            window.shell.destination = destination
        }
        if let raw = environment["ORION_VIEW_MODE"], let mode = ArchitectureViewMode(rawValue: raw) {
            window.shell.viewMode = mode
        }
        if let target = environment["ORION_INSPECT"], let summary = window.summary {
            await inspect(target, in: window, outputDirectory: summary.outputDirectory)
        }
        if environment["ORION_SELECT"] == "first", let summary = window.summary {
            try? await Task.sleep(for: .seconds(2))
            await selectFirst(in: window, outputDirectory: summary.outputDirectory)
        }
        switch environment["ORION_SHOW"] {
        case "sync":
            // After the toolbar has settled: a popover needs its anchor on screen.
            try? await Task.sleep(for: .seconds(2))
            window.isShowingSyncPopover = true
        case "build": window.isBuildingModel = true
        case "clone": window.isCloning = true
        default: break
        }
    }

    private static func selectFirst(in window: RepositoryWindow, outputDirectory: URL) async {
        switch window.shell.destination {
        case .ask:
            if let first = window.askHistory.sessions.first {
                window.askHistory.selectedSessionID = first.id
            }
        case .teaching:
            if let first = window.teaching.concepts.first {
                window.teaching.select(conceptId: first.id, outputDirectory: outputDirectory)
            }
        default:
            break
        }
    }

    private static func inspect(_ target: String, in window: RepositoryWindow, outputDirectory: URL) async {
        guard let model = try? ArchitectureModelLoader.load(outputDirectory: outputDirectory) else { return }
        if target == "questions" {
            window.shell.inspectorContent = .openQuestions(model.uncertainties)
        } else if let node = model.nodes.first(where: { $0.name.localizedStandardContains(target) }) {
            window.shell.inspectorContent = .node(node, model.layer)
        }
    }
}
#endif
