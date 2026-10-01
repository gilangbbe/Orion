import SwiftUI

/// "Checking point 3 of 7 on this iPhone…" -- each point is a model call (Docs/19 M7).
struct GradingProgress: View {
    let judged: Int
    let total: Int

    var body: some View {
        if total > 0 {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
                ProgressView(value: Double(judged), total: Double(total))
                Text("Checking point \(min(judged + 1, total)) of \(total) on this iPhone…")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        } else {
            WorkingRow(text: "Checking your answer on this iPhone…")
        }
    }
}
