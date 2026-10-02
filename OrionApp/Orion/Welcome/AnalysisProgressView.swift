import SwiftUI

/// Docs/14_phase4_5_ui_ux_redesign.md §4.3/§8 M2: Docs/05 Stage 2's four named phases as a real
/// stepper (pending outline -> active spinner -> done checkmark), replacing the generic
/// `ProgressView(progress.currentStage?.rawValue)` that surfaced the internal `PipelineStageID`
/// raw value as the primary UI text. The internal per-stage log is still here, just moved fully
/// into a closed-by-default "Advanced" disclosure (Docs/05 §8's own hidden-by-default rule).
struct AnalysisProgressView: View {
    let repoRoot: URL
    let progress: AnalysisProgressTracker
    @State private var showsAdvanced = false

    private var currentPhaseIndex: Int? {
        progress.currentStage.flatMap { AnalysisProgressStage.allCases.firstIndex(of: $0) }
    }

    var body: some View {
        VStack(spacing: 22) {
            VStack(spacing: 4) {
                Text(repoRoot.lastPathComponent)
                    .font(.title2.bold())
                Text(repoRoot.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            VStack(alignment: .leading, spacing: 2) {
                ForEach(AnalysisProgressStage.allCases, id: \.self) { phase in
                    phaseRow(phase)
                }
            }
            .frame(maxWidth: 340, alignment: .leading)

            DisclosureGroup("Advanced", isExpanded: $showsAdvanced) {
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
                .frame(maxWidth: 340, alignment: .leading)
                .padding(.top, 4)
            }
            .frame(maxWidth: 340)
        }
        .padding(24)
    }

    @ViewBuilder
    private func phaseRow(_ phase: AnalysisProgressStage) -> some View {
        let index = AnalysisProgressStage.allCases.firstIndex(of: phase) ?? 0
        let isDone = currentPhaseIndex.map { index < $0 } ?? false
        let isActive = currentPhaseIndex == index

        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(isDone ? DesignTokens.accent : Color.clear)
                Circle()
                    .strokeBorder(
                        isDone || isActive ? DesignTokens.accent : Color.secondary.opacity(0.35),
                        lineWidth: 1.5)
                if isDone {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                } else if isActive {
                    ProgressView()
                        .controlSize(.mini)
                }
            }
            .frame(width: 20, height: 20)

            Text(phase.rawValue)
                .font(.callout)
                .fontWeight(isActive ? .semibold : .regular)
                .foregroundStyle(isDone || isActive ? Color.primary : Color.secondary)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(phase.rawValue): \(isDone ? "done" : isActive ? "in progress" : "not started yet")")
    }
}
