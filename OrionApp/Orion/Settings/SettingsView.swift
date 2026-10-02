import SwiftUI

/// Orion > Settings… (⌘,). One pane, so the window is titled for it (HIG, Settings, macOS).
/// Per-repository switches stay in each window's toolbar, where the task is; this lists every
/// repository that syncs, including ones that aren't open, so any of them can be stopped.
struct SettingsView: View {
    let sync: IPhoneSync

    var body: some View {
        SyncSettingsPane(sync: sync)
            .frame(width: 480)
            .fixedSize(horizontal: false, vertical: true)
            .navigationTitle("iPhone Sync")
    }
}
