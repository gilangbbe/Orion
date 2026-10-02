import SwiftUI

/// One syncing repository in Settings, with Stop Syncing.
struct SyncedRepositoryRow: View {
    let name: String
    let state: IPhoneSync.State
    let stop: () -> Void

    var body: some View {
        LabeledContent {
            Button("Stop Syncing", action: stop)
        } label: {
            Text(name)
            SyncStateLabel(state: state)
                .font(.callout)
        }
    }
}
