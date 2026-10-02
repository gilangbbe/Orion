import SwiftUI

/// Diagnostics (Docs/05 §8, Docs/14 §4.9, Docs/20 R6): what was analyzed and how, the
/// architecture model's last build (moved here from the sidebar footer, with its cost), and the
/// last Ask and analysis traces. Both traces are last-only (Docs/14 §7 Decision 2): an empty
/// section means "hasn't happened in this window yet", not "cleared".
struct DiagnosticsView: View {
    let session: DiagnosticsSession
    let semantic: SemanticInvestigationSession
    let summary: RepositorySummary

    var body: some View {
        Form {
            RepositoryDiagnosticsSection(summary: summary)
            ArchitectureModelDiagnosticsSection(state: semantic.state)
            Section("Last Ask") {
                if let trace = session.lastAskTrace {
                    AskTraceRows(trace: trace)
                } else {
                    Text("No questions asked in this window yet.")
                        .foregroundStyle(.secondary)
                }
            }
            Section("Last Analysis Run") {
                if let stages = session.lastAnalysisStages, !stages.isEmpty {
                    ForEach(stages) { entry in
                        LabeledContent(entry.stage.rawValue) {
                            Text(entry.startedAt, format: .dateTime.hour().minute().second().secondFraction(.fractional(3)))
                                .monospacedDigit()
                        }
                    }
                } else {
                    Text("This repository was already analyzed when it opened, so there's no run to show.")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }
}

#Preview {
    DiagnosticsView(
        session: DiagnosticsSession(), semantic: SemanticInvestigationSession(),
        summary: RepositorySummary(
            repoRoot: URL(fileURLWithPath: "/tmp/example"),
            outputDirectory: URL(fileURLWithPath: "/tmp/example/.orion"),
            languages: ["python"], fileCount: 135, symbolCount: 3225, relationshipCount: 815,
            resolver: "scip-python", parseErrorCount: 0, diagnosticCount: 0, totalDurationMs: 420)
    )
    .frame(width: 560, height: 600)
}
