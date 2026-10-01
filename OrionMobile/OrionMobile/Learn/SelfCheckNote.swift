import SwiftUI

/// Docs/17 Decision 10: until the grader clears its calibration gate, a grade is a self-check.
struct SelfCheckNote: View {
    var body: some View {
        Label("Self-check only. Grading runs on this iPhone and isn't calibrated against expert review yet, so mastery isn't scored.", systemImage: "info.circle")
            .font(.footnote)
            .foregroundStyle(.secondary)
    }
}
