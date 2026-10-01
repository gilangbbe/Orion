import SwiftUI

/// Why a feature that runs on the on-device model can't run now -- one state per reason the
/// framework reports (the Foundation Models skill: check availability before any session).
/// Shared by Ask and Learn.
struct ModelUnavailableView: View {
    let availability: AskModel.Availability
    /// "Ask" or "Learn".
    let feature: String
    let onRetry: () -> Void

    var body: some View {
        switch availability {
        case .appleIntelligenceNotEnabled:
            ContentUnavailableView {
                Label("Apple Intelligence Is Off", systemImage: "apple.intelligence")
            } description: {
                Text("\(feature) runs on Apple's on-device model. Turn on Apple Intelligence in Settings to use it.")
            } actions: {
                Button("Check Again", action: onRetry)
            }
        case .modelNotReady:
            ContentUnavailableView {
                Label("Getting Ready", systemImage: "arrow.down.circle")
            } description: {
                Text("The on-device model is still downloading or setting up. Try again in a few minutes.")
            } actions: {
                Button("Check Again", action: onRetry)
            }
        case .deviceNotEligible:
            ContentUnavailableView(
                "Not Available on This iPhone", systemImage: "iphone.slash",
                description: Text("\(feature) needs an iPhone that supports Apple Intelligence. Explore still works."))
        case .unavailable, .available:
            ContentUnavailableView(
                "\(feature) Isn't Available", systemImage: "exclamationmark.bubble",
                description: Text("The on-device model can't be used right now."))
        }
    }
}
