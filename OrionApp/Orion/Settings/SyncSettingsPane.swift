import SwiftUI

/// The iCloud account state and the repositories that sync to the iPhone.
struct SyncSettingsPane: View {
    let sync: IPhoneSync
    @State private var isICloudAvailable: Bool?

    var body: some View {
        Form {
            Section {
                ICloudAccountRow(isAvailable: isICloudAvailable)
            }
            Section {
                if sync.enabledKeys.isEmpty {
                    Text("No repositories sync yet. Open one and choose Sync to iPhone in its toolbar.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(sync.enabledKeys, id: \.self) { key in
                        SyncedRepositoryRow(
                            name: sync.repositoryName(libraryKey: key) ?? "Waiting for first upload",
                            state: sync.state(for: key),
                            stop: { stop(key) })
                    }
                }
            } header: {
                Text("Repositories")
            } footer: {
                Text("Each sends its knowledge, with the code snippets its evidence cites, to your private iCloud. Stopping deletes it from iCloud; your iPhone keeps its copy.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task { isICloudAvailable = await sync.isICloudAvailable() }
    }

    private func stop(_ key: String) {
        Task { await sync.stopSyncing(libraryKey: key) }
    }
}
