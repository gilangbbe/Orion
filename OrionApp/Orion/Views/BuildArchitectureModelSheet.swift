import SwiftUI

/// Docs/13_phase4_architecture_ui.md M3's cost-confirmation gate -- Docs/06 §6 usage
/// constraints ("respect account limits") and the real per-run costs Phase 2/3 measured
/// ($0.17-$1.77, several minutes). Never triggered automatically; this sheet is the only way
/// `SemanticInvestigationRunner` ever gets invoked.
///
/// Docs/14_phase4_5_ui_ux_redesign.md §4.10/§8 M5: visual-only restyle -- an icon-led header and
/// the cost control set apart in its own card, so the real consequence (a paid API call, several
/// minutes) reads clearly before the action, not after (Docs/06 §6 / HAX G16: "convey the
/// consequences of user actions"). The sparkles icon's tint reuses `DesignTokens.interpretation`
/// -- the same hue `EpistemicBadge(.interpretation)` renders the "Semantic view" banner in once
/// this investigation completes, since that's exactly the tier of knowledge this action produces.
/// No logic changed: `SemanticInvestigationRunner.run(...)` is called exactly as it always was.
struct BuildArchitectureModelSheet: View {
    @Environment(\.dismiss) private var dismiss
    let repoRoot: URL
    let outputDirectory: URL
    let session: SemanticInvestigationSession

    @State private var maxBudgetUsd: Double = 1.00

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .foregroundStyle(DesignTokens.interpretation)
                Text("Build Architecture Model")
                    .font(.title2.bold())
            }
            Text(
                "This sends the repository's Code Graph to Claude Code, which groups its symbols "
                    + "into semantic components and evidence-backed claims -- a real API call, real "
                    + "cost, and several minutes of investigation (Phase 2/3 measured $0.17-$1.77 "
                    + "per run on comparable repositories)."
            )
            .font(.callout)
            .foregroundStyle(.secondary)

            HStack {
                Text("Cost ceiling").font(.callout.weight(.medium))
                Spacer()
                Stepper(value: $maxBudgetUsd, in: 0.25...5.00, step: 0.25) {
                    Text(maxBudgetUsd, format: .currency(code: "USD"))
                        .font(.callout.monospacedDigit())
                        .frame(minWidth: 56, alignment: .trailing)
                }
            }
            .padding(12)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.control))

            HStack {
                Button("Cancel") { dismiss() }
                    .buttonStyle(.glass)
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
                .buttonStyle(.glassProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(minWidth: 420)
    }
}
