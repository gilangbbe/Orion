import SwiftUI

/// The last Build Architecture Model run in this window: outcome, what it produced, and what it
/// cost (Docs/13 M3; shown in the sidebar footer until Docs/20 R1).
struct ArchitectureModelDiagnosticsSection: View {
    let state: SemanticInvestigationSession.State

    var body: some View {
        Section("Architecture Model") {
            switch state {
            case .idle:
                Text("Not built in this window. Architecture shows the most recent model.")
                    .foregroundStyle(.secondary)
            case .investigating:
                Label {
                    Text("Claude Code is investigating…")
                } icon: {
                    ProgressView().controlSize(.small)
                }
            case .completed(let result):
                LabeledContent("Outcome") {
                    Label(Self.outcomeTitle(result.outcome), systemImage: result.outcome == "verified" ? "checkmark.seal" : "exclamationmark.triangle")
                }
                LabeledContent("Components", value: result.componentCount, format: .number)
                LabeledContent("Claims", value: result.claimCount, format: .number)
                if result.droppedComponentCount + result.droppedClaimCount > 0 {
                    LabeledContent("Dropped by validation", value: "\(result.droppedComponentCount) components, \(result.droppedClaimCount) claims")
                }
                if let cost = result.totalCostUsd {
                    LabeledContent("Cost", value: cost, format: .currency(code: "USD"))
                }
                if let durationMs = result.durationMs {
                    LabeledContent("Time") {
                        Text(Duration.milliseconds(durationMs), format: .units(allowed: [.minutes, .seconds], width: .abbreviated))
                    }
                }
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
            }
        }
    }

    /// `verified`, `partially_verified`, … in words.
    static func outcomeTitle(_ outcome: String) -> String {
        outcome.replacing("_", with: " ").capitalized
    }
}
