import SwiftUI

/// The three depths of question. Transfer questions come from the Mac (Docs/19 M7).
struct DepthPicker: View {
    let isBusy: Bool
    let choose: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
            Text("Choose a depth")
                .font(.title3)
                .bold()
            DepthButton(band: 1, hint: "State what this is and does.", isBusy: isBusy, choose: choose)
            DepthButton(band: 2, hint: "Explain how it relates to a neighbouring concept.", isBusy: isBusy, choose: choose)
            DepthButton(band: 3, hint: "Reason about what breaks if it changes. Written on your Mac.", isBusy: isBusy, choose: choose)
        }
    }
}
