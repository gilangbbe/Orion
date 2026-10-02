import SwiftUI

/// "Handle iCloud being unavailable … unobtrusively noting that changes won't reach other
/// devices until iCloud access is restored" (HIG, iCloud).
struct ICloudAccountRow: View {
    /// `nil` while checking.
    let isAvailable: Bool?

    var body: some View {
        LabeledContent("iCloud") {
            switch isAvailable {
            case nil:
                ProgressView().controlSize(.small)
            case true?:
                Label("Signed in", systemImage: "checkmark.icloud")
            case false?:
                Label("Unavailable. Changes won't reach your iPhone until you sign in to iCloud on this Mac.", systemImage: "icloud.slash")
                    .foregroundStyle(.secondary)
            }
        }
    }
}
