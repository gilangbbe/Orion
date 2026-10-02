import SwiftUI

/// The Repository menu: actions on the open repository (HIG, The menu bar: "Provide app-specific
/// menus for custom commands, even ones available elsewhere").
struct RepositoryMenuItems: View {
    let window: RepositoryWindow?

    var body: some View {
        Button("Build Architecture Model…", action: buildModel)
            .keyboardShortcut("b", modifiers: [.command, .shift])
            .disabled(!canBuildModel)
        Divider()
        Button("New Ask Session", action: newAskSession)
            .keyboardShortcut("n", modifiers: [.command, .option])
            .disabled(window?.summary == nil)
        Button("Practise Next Concept", action: practiseNext)
            .keyboardShortcut("p", modifiers: [.command, .option])
            .disabled(window?.summary == nil)
        Divider()
        Button(window?.isSyncing == true ? "Stop Syncing to iPhone" : "Sync to iPhone", action: toggleSync)
            .disabled(window?.syncKey == nil)
        Button("Sync Now", action: syncNow)
            .disabled(window?.isSyncing != true)
        Divider()
        Button("Show in Finder", action: showInFinder)
            .keyboardShortcut("r", modifiers: [.command, .shift])
            .disabled(window?.summary == nil)
    }

    private var canBuildModel: Bool {
        guard let window, window.summary != nil else { return false }
        return window.semantic.state != .investigating
    }

    private func buildModel() {
        window?.isBuildingModel = true
    }

    private func toggleSync() {
        guard let window else { return }
        window.setSyncing(!window.isSyncing)
    }

    private func newAskSession() {
        window?.newAskSession()
    }

    private func practiseNext() {
        window?.practiseNext()
    }

    private func syncNow() {
        window?.syncNow()
    }

    private func showInFinder() {
        window?.showInFinder()
    }
}
