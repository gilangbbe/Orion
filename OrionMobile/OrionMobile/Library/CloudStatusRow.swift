import SwiftUI

/// What iCloud sync is doing (Docs/19 M5), with the account gate spelled out.
struct CloudStatusRow: View {
    let cloud: CloudSync

    var body: some View {
        switch cloud.account {
        case .noAccount:
            status("Sign in to iCloud in Settings to receive repositories from your Mac.", "icloud.slash")
        case .restricted, .temporarilyUnavailable:
            status("iCloud isn't available right now.", "exclamationmark.icloud")
        case .unknown, .available:
            switch cloud.status {
            case .idle:
                status("iCloud sync is on.", "icloud")
            case .fetching:
                Label {
                    Text("Checking iCloud for updates…")
                } icon: {
                    ProgressView()
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
            case .upToDate(let date):
                status("Up to date with your Mac · checked \(date.formatted(.relative(presentation: .named)))", "checkmark.icloud")
            case .failed(let message):
                StatusLabel("iCloud: \(message)", systemImage: "exclamationmark.icloud", tint: .orange, textStyle: .secondary)
                    .font(.subheadline)
            }
        }
    }

    private func status(_ text: String, _ symbol: String) -> some View {
        Label(text, systemImage: symbol)
            .font(.subheadline)
            .foregroundStyle(.secondary)
    }
}
