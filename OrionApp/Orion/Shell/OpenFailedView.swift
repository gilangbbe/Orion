import SwiftUI

/// A repository that couldn't be opened or analyzed: what went wrong, and the way back.
struct OpenFailedView: View {
    let message: String
    let tryAgain: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("Couldn't Open Repository", systemImage: "exclamationmark.triangle")
        } description: {
            Text(message)
                .textSelection(.enabled)
        } actions: {
            Button("Choose Another Repository", action: tryAgain)
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
