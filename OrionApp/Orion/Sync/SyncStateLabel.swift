import SwiftUI

/// One sync state in words, with a symbol that isn't the only cue (HIG, Color).
struct SyncStateLabel: View {
    let state: IPhoneSync.State

    var body: some View {
        switch state {
        case .off:
            Label("Not syncing", systemImage: "icloud.slash")
                .foregroundStyle(.secondary)
        case .preparing:
            Label {
                Text("Preparing snapshot…")
            } icon: {
                ProgressView().controlSize(.small)
            }
        case .pending:
            Label {
                Text("Uploading to iCloud…")
            } icon: {
                ProgressView().controlSize(.small)
            }
        case .uploaded(let date):
            Label {
                Text("Synced \(date, format: .relative(presentation: .named))")
            } icon: {
                Image(systemName: "checkmark.icloud")
                    .foregroundStyle(.green)
            }
        case .failed(let message):
            Label {
                Text(message)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "exclamationmark.icloud")
                    .foregroundStyle(.orange)
            }
        }
    }
}
