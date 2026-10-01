import SwiftUI

/// Something the on-device model is doing.
struct WorkingRow: View {
    let text: String

    var body: some View {
        Label {
            Text(text)
        } icon: {
            ProgressView()
        }
        .foregroundStyle(.secondary)
    }
}
