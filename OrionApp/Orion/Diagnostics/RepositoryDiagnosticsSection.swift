import SwiftUI

/// What was analyzed and how (Docs/14 §8 M8.5 item 1: moved here from the sidebar header).
struct RepositoryDiagnosticsSection: View {
    let summary: RepositorySummary

    var body: some View {
        Section {
            LabeledContent("Location") {
                Text(summary.repoRoot.path)
                    .textSelection(.enabled)
                    .truncationMode(.middle)
            }
            LabeledContent("Languages", value: summary.languages.joined(separator: ", "))
            LabeledContent("Files", value: summary.fileCount, format: .number)
            LabeledContent("Symbols", value: summary.symbolCount, format: .number)
            LabeledContent("Relationships", value: summary.relationshipCount, format: .number)
            LabeledContent("Resolver", value: summary.resolver)
            if summary.parseErrorCount > 0 {
                LabeledContent("Parse errors", value: summary.parseErrorCount, format: .number)
            }
            if summary.diagnosticCount > 0 {
                LabeledContent("Diagnostics", value: summary.diagnosticCount, format: .number)
            }
            LabeledContent("Analysis time") {
                Text(Duration.milliseconds(summary.totalDurationMs), format: .units(allowed: [.seconds, .milliseconds], width: .abbreviated))
            }
        } header: {
            Text("Repository")
        } footer: {
            if summary.resolver == "none" {
                // Docs/06 §7 failure transparency: in a real run `none` always means SCIP
                // (scip-python via npx) wasn't available, never a choice.
                Label(
                    "scip-python (Pyright) wasn't available, so calls, extends and implements weren't resolved. Symbols, imports and module structure are complete.",
                    systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
            }
        }
    }
}
