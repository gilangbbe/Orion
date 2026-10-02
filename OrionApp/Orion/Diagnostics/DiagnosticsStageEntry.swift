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
