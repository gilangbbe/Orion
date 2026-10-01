import SwiftUI

/// The sidebar footer's "Sync to iPhone" control (Docs/19 M5): the per-repository switch, what
/// sync is doing, and -- because what's uploaded includes code -- a plain statement of it.
struct IPhoneSyncSection: View {
    let repoRoot: URL
    let outputDirectory: URL
    @State private var sync = IPhoneSync.shared
    @State private var libraryKey: String?

    var body: some View {
        Group {
            if let libraryKey {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle(isOn: binding(libraryKey)) {
                        Label("Sync to iPhone", systemImage: "iphone")
                            .font(.caption)
                    }
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    if sync.isEnabled(libraryKey) {
                        status(sync.state(for: libraryKey))
                        Text("Sends this repository's knowledge, with the code snippets its evidence cites, to your private iCloud.")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .task(id: outputDirectory) {
            let outputDirectory = outputDirectory
            libraryKey = await Task.detached { try? IPhoneSync.libraryKey(outputDirectory: outputDirectory) }.value
        }
    }

    private func binding(_ libraryKey: String) -> Binding<Bool> {
        Binding(
            get: { sync.isEnabled(libraryKey) },
            set: { on in
                Task {
                    await sync.setEnabled(on, libraryKey: libraryKey, repoRoot: repoRoot, outputDirectory: outputDirectory)
                }
            })
    }

    @ViewBuilder
    private func status(_ state: IPhoneSync.State) -> some View {
        HStack(spacing: 6) {
            switch state {
            case .off:
                EmptyView()
            case .preparing:
                ProgressView().controlSize(.mini)
                Text("Preparing snapshot…")
            case .pending:
                ProgressView().controlSize(.mini)
                Text("Uploading to iCloud…")
            case .uploaded(let date):
                Image(systemName: "checkmark.icloud").foregroundStyle(.green)
                Text("Synced \(date.formatted(.relative(presentation: .named)))")
            case .failed(let message):
                Image(systemName: "exclamationmark.icloud").foregroundStyle(.orange)
                Text(message).lineLimit(2)
            }
            Spacer(minLength: 0)
            if let libraryKey, state != .preparing {
                Button("Sync Now") {
                    Task { await sync.syncNow(libraryKey: libraryKey, repoRoot: repoRoot, outputDirectory: outputDirectory) }
                }
                .buttonStyle(.link)
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }
}
