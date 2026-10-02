import Foundation
import OrionCodeIntel

/// Docs/14 §4.9/§8 M8: Docs/05 §8's reserved "advanced diagnostic view," finally given a real
/// home. Deliberately *last-only* (Docs/14 §7 Decision 2) -- two overwritable optionals, replaced
/// wholesale by every new Ask call / analysis run, never accumulated into a rolling log. This
/// mirrors `AppShellState`/`SemanticInvestigationSession`: one more single-purpose shell-level
/// object `ContentView` owns and recreates per repository, so a previous repository's traces never
/// leak into the next one.
@MainActor
@Observable
final class DiagnosticsSession {
    private(set) var lastAskTrace: DiagnosticsAskTrace?
    private(set) var lastAnalysisStages: [DiagnosticsStageEntry]?

    /// A failed Ask call has no routing decision or tool trace to show -- deliberately leaves the
    /// previous successful trace (if any) in place rather than overwriting it with nothing.
    func recordAsk(question: String, outcome: AskOutcome) {
        guard case .answered(let summary) = outcome else { return }
        lastAskTrace = DiagnosticsAskTrace(question: question, summary: summary)
    }

    func recordAnalysis(stageHistory: [(stage: PipelineStageID, startedAt: Date)]) {
        lastAnalysisStages = stageHistory.map { DiagnosticsStageEntry(stage: $0.stage, startedAt: $0.startedAt) }
    }
}
