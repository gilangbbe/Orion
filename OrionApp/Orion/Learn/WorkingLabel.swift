import SwiftUI

/// Something slow is running, and what it is.
struct WorkingLabel: View {
    let text: String

    var body: some View {
        Label {
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            ProgressView().controlSize(.small)
        }
        .foregroundStyle(.secondary)
    }
}
