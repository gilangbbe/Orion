import Foundation
import OrionCodeIntel

/// One row of the raw pipeline stage log, Docs/14_phase4_5_ui_ux_redesign.md §4.9/§8 M8 -- a
/// UI-friendly, `Identifiable`/`Equatable` projection of `AnalysisProgressTracker.stageHistory`'s
/// `(stage:startedAt:)` tuple. Tuples can't conform to either protocol, which both
/// `DiagnosticsView`'s `ForEach` and this milestone's own regression test need.
struct DiagnosticsStageEntry: Identifiable, Equatable {
    let stage: PipelineStageID
    let startedAt: Date

    var id: String { "\(stage.rawValue)-\(startedAt.timeIntervalSinceReferenceDate)" }
}

/// One Ask call's routing/trace detail, Docs/14 §4.9 -- the question alongside the
/// `AskResultSummary` that already carries `routingMethod`/`routingConfidence`/`rationale`/
/// `toolCalls` (currently only shown per-answer behind `AskEntryView`'s own "Explain" disclosure).
/// `AskResultSummary` alone doesn't say which question produced it, so this pairs the two.
struct DiagnosticsAskTrace: Equatable {
    let question: String
    let summary: AskResultSummary
}

/// Docs/14 §4.9/§8 M8: Docs/05 §8's reserved "advanced diagnostic view," finally given a real
/// home. Deliberately *last-only* (Docs/14 §7 Decision 2) -- two overwritable optionals, replaced
/// wholesale by every new Ask call / analysis run, never accumulated into a rolling log. This
/// mirrors `AppShellState`/`SemanticInvestigationSession`: one more single-purpose shell-level
/// object `ContentView` owns and recreates per repository, so a previous repository's traces never
/// leak into the next one.
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
