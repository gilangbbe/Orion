import SwiftUI

/// Where a syncing repository's upload stands, with Sync Now. Shared by the toolbar popover and
/// Settings.
struct SyncStatusRow: View {
    let state: IPhoneSync.State
    let syncNow: () -> Void

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            SyncStateLabel(state: state)
            Spacer(minLength: 0)
            Button("Sync Now", action: syncNow)
                .disabled(state == .preparing)
        }
        .font(.callout)
    }
}
