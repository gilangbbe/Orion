import Foundation

/// The pipeline stages [10_phase1_deterministic_code_intelligence.md](../../../../Docs/10_phase1_deterministic_code_intelligence.md)
/// describes, in the order `AnalysisPipeline.run(_:)` actually executes them (imports/dependency
/// graph runs before SCIP resolution in the real implementation, ahead of Docs/10's own numbering
/// -- this enum follows the code, not the doc). Added in Phase 4
/// ([13_phase4_architecture_ui.md](../../../../Docs/13_phase4_architecture_ui.md) M2) purely so a
/// UI can show real per-stage progress ([05_user_flow_and_ux.md](../../../../Docs/05_user_flow_and_ux.md)
/// Stage 2); Phase 1 itself has no use for this and never calls it.
///
/// `relationships` fires only when SCIP actually resolves (not under `SCIP_UNAVAILABLE`
/// degradation) -- there is no separate relationship-building work to report when it doesn't.
public enum PipelineStageID: String, CaseIterable, Sendable {
    case ingestion
    case ast
    case symbols
    case imports
    case scip
    case relationships
    case testMapping
    case assembly
}

/// Callback surface for `AnalysisPipeline.run(_:progress:)`. Strictly additive and optional --
/// `run(_:)` without a `progress` argument behaves exactly as it always has. This is the only
/// change Phase 4 makes to `OrionCodeIntel`/`OrionAgent`
/// ([13_phase4_architecture_ui.md](../../../../Docs/13_phase4_architecture_ui.md) M2); the
/// complete pre-existing Phase 1/2/3 test suite staying green is the acceptance bar for it.
public protocol AnalysisProgressReporting: Sendable {
    func pipelineDidStart(stage: PipelineStageID)
}
