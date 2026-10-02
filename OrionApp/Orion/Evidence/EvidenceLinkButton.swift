import SwiftUI

/// A symbol or anchor that opens the code it cites. The system link style, so it looks and
/// behaves like a link everywhere on the Mac, instead of hard-coded blue text.
struct EvidenceLinkButton: View {
    let title: String
    let evidence: EvidenceDetail
    let show: (EvidenceDetail) -> Void

    var body: some View {
        Button(action: open) {
            Text(title)
                .font(.callout.monospaced())
                .multilineTextAlignment(.leading)
        }
        .buttonStyle(.link)
        .help("Show the code: \(evidence.anchor)")
    }

    private func open() {
        show(evidence)
    }
}
