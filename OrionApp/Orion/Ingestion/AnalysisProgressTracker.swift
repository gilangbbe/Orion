import Foundation
import Observation
import OrionCodeIntel

/// Docs/05_user_flow_and_ux.md Stage 2's four progress labels -- multiple internal
/// `PipelineStageID`s collapse onto each one (Docs/13_phase4_architecture_ui.md M2).
enum AnalysisProgressStage: String, CaseIterable {
    case mappingRepositoryStructure = "Mapping repository structure"
    case verifyingDependencies = "Verifying dependencies"
    case identifyingComponents = "Identifying components"
    case buildingArchitecture = "Building architecture"

    /// Table-tested against all 8 `PipelineStageID` cases (Docs/13's own testing plan for this
    /// milestone) -- a pure function, independent of `AnalysisProgressTracker`'s cross-thread
    /// bookkeeping below.
    static func uiStage(for stage: PipelineStageID) -> AnalysisProgressStage {
        switch stage {
        case .ingestion, .ast, .symbols: return .mappingRepositoryStructure
        case .imports, .scip: return .verifyingDependencies
        case .relationships, .testMapping: return .identifyingComponents
        case .assembly: return .buildingArchitecture
        }
    }
}

/// Forwards `OrionCodeIntel.AnalysisPipeline`'s per-stage callback into observable state the UI
/// can bind to. `pipelineDidStart` is called from `AnalysisRunner`'s background task, not the
/// main thread -- protected by a lock rather than assumed safe, the same posture
/// `OrionAgent.ModelDownloadProgressReporter` (Docs/12 M6) already established for an identical
/// "background callback updates state a SwiftUI view reads" shape.
@Observable
final class AnalysisProgressTracker: AnalysisProgressReporting, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var currentStage: AnalysisProgressStage?
    private(set) var stageHistory: [(stage: PipelineStageID, startedAt: Date)] = []

    func pipelineDidStart(stage: PipelineStageID) {
        lock.lock()
        stageHistory.append((stage, Date()))
        currentStage = AnalysisProgressStage.uiStage(for: stage)
        lock.unlock()
    }
}
