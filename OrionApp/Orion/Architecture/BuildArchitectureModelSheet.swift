import SwiftUI

/// Build Architecture Model's confirmation (Docs/13 M3, Docs/14 §4.10, Docs/20 R2): what it does,
/// what it costs, and a cost limit, before a paid Claude Code call that takes minutes -- "convey
/// the consequences of user actions" (Docs/06 §6, HAX G16). This sheet is the only way
/// `SemanticInvestigationRunner` ever runs. Cancel and a default Start button (HIG, Sheets).
struct BuildArchitectureModelSheet: View {
    let repoRoot: URL
    let outputDirectory: URL
    let session: SemanticInvestigationSession

    @Environment(\.dismiss) private var dismiss
    @State private var maxBudgetUsd = 1.00

    var body: some View {
        Form {
            Section {
                Label {
                    Text("Claude Code reads \(repoRoot.lastPathComponent)'s code graph and groups its symbols into components, with evidence-backed claims about each. It takes several minutes and is billed to your Claude account: comparable repositories cost $0.17–$1.77.")
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "sparkles")
                        .foregroundStyle(DesignTokens.interpretation)
                }
            } header: {
                Text("Build Architecture Model")
                    .font(.headline)
            }
            Section {
                LabeledContent("Cost limit") {
                    Stepper(value: $maxBudgetUsd, in: 0.25...5.00, step: 0.25) {
                        Text(maxBudgetUsd, format: .currency(code: "USD"))
                            .monospacedDigit()
                    }
                }
            } footer: {
                Text("The investigation stops when it reaches this amount.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel", action: cancel)
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Start Investigation", action: start)
            }
        }
    }

    private func cancel() {
        dismiss()
    }

    private func start() {
        let budget = maxBudgetUsd
        let repoRoot = repoRoot
        let outputDirectory = outputDirectory
        let session = session
        dismiss()
        Task {
            await SemanticInvestigationRunner.run(
                repoRoot: repoRoot, outputDirectory: outputDirectory, session: session,
                maxBudgetUsd: budget, timeoutSeconds: 900)
        }
    }
}
