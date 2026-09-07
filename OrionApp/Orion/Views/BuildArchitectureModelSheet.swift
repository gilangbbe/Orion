import SwiftUI

/// Docs/13_phase4_architecture_ui.md M3's cost-confirmation gate -- Docs/06 §6 usage
/// constraints ("respect account limits") and the real per-run costs Phase 2/3 measured
/// ($0.17-$1.77, several minutes). Never triggered automatically; this sheet is the only way
/// `SemanticInvestigationRunner` ever gets invoked.
struct BuildArchitectureModelSheet: View {
    @Environment(\.dismiss) private var dismiss
    let repoRoot: URL
    let outputDirectory: URL
    let session: SemanticInvestigationSession

    @State private var maxBudgetUsd: Double = 1.00

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Build Architecture Model")
                .font(.title2.bold())
            Text(
                "This sends the repository's Code Graph to Claude Code, which groups its symbols "
                    + "into semantic components and evidence-backed claims -- a real API call, real "
                    + "cost, and several minutes of investigation (Phase 2/3 measured $0.17-$1.77 "
                    + "per run on comparable repositories)."
            )
            .font(.callout)
            .foregroundStyle(.secondary)

            HStack {
                Text("Cost ceiling")
                Spacer()
                Stepper(value: $maxBudgetUsd, in: 0.25...5.00, step: 0.25) {
                    Text(maxBudgetUsd, format: .currency(code: "USD"))
                }
            }

            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Button("Start Investigation") {
                    let budget = maxBudgetUsd
                    dismiss()
                    Task {
                        await SemanticInvestigationRunner.run(
                            repoRoot: repoRoot, outputDirectory: outputDirectory, session: session,
                            maxBudgetUsd: budget, timeoutSeconds: 900)
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(minWidth: 420)
    }
}
