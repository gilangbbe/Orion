import SwiftUI

/// Docs/05_user_flow_and_ux.md Stages 1-2: repository identity + live analysis progress.
/// Internal tool traces (raw pipeline stage names, timestamps) are hidden behind a closed-by-
/// default disclosure, per Docs/05 §8 ("hidden by default" -- not undiscoverable).
struct AnalysisProgressView: View {
    let repoRoot: URL
    let progress: AnalysisProgressTracker
    @State private var showsDetails = false

    var body: some View {
        VStack(spacing: 16) {
            VStack(spacing: 4) {
                Text(repoRoot.lastPathComponent)
                    .font(.title2.bold())
                Text(repoRoot.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            ProgressView(progress.currentStage?.rawValue ?? "Starting…")
                .progressViewStyle(.linear)
                .frame(maxWidth: 320)

            DisclosureGroup("Details", isExpanded: $showsDetails) {
                VStack(alignment: .leading, spacing: 4) {
                    if progress.stageHistory.isEmpty {
                        Text("No stages reported yet.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(Array(progress.stageHistory.enumerated()), id: \.offset) { _, entry in
                        Text(
                            "\(entry.stage.rawValue) — \(entry.startedAt.formatted(date: .omitted, time: .standard))"
                        )
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: 320, alignment: .leading)
                .padding(.top, 4)
            }
            .frame(maxWidth: 320)
        }
        .padding(24)
    }
}
