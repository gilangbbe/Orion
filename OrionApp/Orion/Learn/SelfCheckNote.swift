import SwiftUI

/// Docs/17 Decision 10: until the grader is calibrated against expert review, every verdict is a
/// self-check and no mastery is stored.
struct SelfCheckNote: View {
    var body: some View {
        Label {
            Text("Self-check only. Grading isn't calibrated against expert review yet, so use the breakdown to reflect, not as a verdict. Your mastery isn't being scored.")
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "info.circle")
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }
}
