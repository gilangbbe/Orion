import SwiftUI

/// The switch, what sync is doing, and -- because what's uploaded includes code -- a plain
/// statement of it (Docs/19 M5). Opened from the toolbar's Sync to iPhone button.
struct SyncPopover: View {
    let window: RepositoryWindow
    @State private var isOn = false

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
            Toggle(isOn: $isOn) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Sync to iPhone")
                        .font(.headline)
                    Text("Explore, ask about and learn \(repositoryName) in Orion on your iPhone.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.switch)
            .disabled(window.syncKey == nil)

            if window.syncKey == nil {
                Text("Available once this repository has been analyzed.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else if isOn {
                SyncStatusRow(state: state, syncNow: window.syncNow)
            }

            Divider()
            Label {
                Text("Sends the repository's knowledge, with the code snippets its evidence cites, to your private iCloud. Only your devices can read it.")
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "lock.icloud")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        .padding(DesignTokens.Spacing.lg)
        .frame(width: 320)
        .task { isOn = window.isSyncing }
        .onChange(of: isOn) { _, on in
            if on != window.isSyncing {
                window.setSyncing(on)
            }
        }
    }

    private var repositoryName: String {
        window.summary?.repoRoot.lastPathComponent ?? "this repository"
    }

    private var state: IPhoneSync.State {
        guard let key = window.syncKey else { return .off }
        return window.sync.state(for: key)
    }
}
