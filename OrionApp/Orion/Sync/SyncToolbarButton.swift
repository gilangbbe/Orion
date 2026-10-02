import SwiftUI

/// "Sync to iPhone" in the window's toolbar (Docs/20 R1), replacing Docs/19 M5's sidebar-footer
/// switch. Its symbol shows the state at a glance; clicking it opens `SyncPopover`. The switch
/// itself lives in the popover: "Use switches … in the window body, not the window frame" (HIG,
/// Toggles, macOS). Repository > Sync to iPhone is the menu bar's copy.
struct SyncToolbarButton: View {
    @Bindable var window: RepositoryWindow

    var body: some View {
        Button("Sync to iPhone", systemImage: symbol, action: showPopover)
            .help(help)
            .popover(isPresented: $window.isShowingSyncPopover, arrowEdge: .bottom) {
                SyncPopover(window: window)
            }
    }

    private var state: IPhoneSync.State {
        guard let key = window.syncKey else { return .off }
        return window.sync.state(for: key)
    }

    private var symbol: String {
        Self.symbol(for: state)
    }

    private var help: String {
        window.isSyncing ? "Syncing to iPhone" : "Sync this repository to Orion on your iPhone"
    }

    private func showPopover() {
        window.isShowingSyncPopover = true
    }

    static func symbol(for state: IPhoneSync.State) -> String {
        switch state {
        case .off: "iphone"
        case .preparing, .pending: "iphone.and.arrow.forward"
        case .uploaded: "iphone.badge.checkmark"
        case .failed: "iphone.badge.exclamationmark"
        }
    }
}
