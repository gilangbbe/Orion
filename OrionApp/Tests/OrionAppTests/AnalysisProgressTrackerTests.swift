import XCTest

@testable import Orion
import OrionCodeIntel

final class AnalysisProgressStageTests: XCTestCase {
    /// Table-tested against every `PipelineStageID` case (Docs/13 M2's own testing plan) --
    /// each of the 8 real pipeline stages must collapse onto exactly one of Docs/05 Stage 2's
    /// four progress labels, and every case must be covered (no silent `default:` gap).
    private static let expected: [PipelineStageID: AnalysisProgressStage] = [
        .ingestion: .mappingRepositoryStructure,
        .ast: .mappingRepositoryStructure,
        .symbols: .mappingRepositoryStructure,
        .imports: .verifyingDependencies,
        .scip: .verifyingDependencies,
        .relationships: .identifyingComponents,
        .testMapping: .identifyingComponents,
        .assembly: .buildingArchitecture,
    ]

    func testEveryPipelineStageMapsToTheExpectedUILabel() {
        for stage in PipelineStageID.allCases {
            XCTAssertEqual(
                AnalysisProgressStage.uiStage(for: stage), Self.expected[stage],
                "unexpected UI stage for \(stage)")
        }
    }

    func testAllPipelineStagesAreCoveredByTheExpectationTable() {
        // Guards against a future PipelineStageID case being added without updating this test.
        XCTAssertEqual(Set(Self.expected.keys), Set(PipelineStageID.allCases))
    }

    /// Docs/14_phase4_5_ui_ux_redesign.md §8 M2's stepper index -- table-tested the same way as
    /// `uiStage(for:)` above, since it's just that mapping's position in `allCases`.
    func testUIPhaseIndexMatchesTheStagesPositionInAllCases() {
        for stage in PipelineStageID.allCases {
            let expectedIndex = AnalysisProgressStage.allCases.firstIndex(
                of: Self.expected[stage]!)!
            XCTAssertEqual(
                AnalysisProgressStage.uiPhaseIndex(for: stage), expectedIndex,
                "unexpected phase index for \(stage)")
        }
    }

    func testUIPhaseIndexIsMonotonicNonDecreasingInPipelineExecutionOrder() {
        // The stepper only makes sense if later pipeline stages never map to an earlier phase --
        // this is what actually lets the view mark "phases before the current one" as done.
        var previousIndex = -1
        for stage in PipelineStageID.allCases {
            let index = AnalysisProgressStage.uiPhaseIndex(for: stage)
            XCTAssertGreaterThanOrEqual(
                index, previousIndex, "\(stage) regressed to an earlier phase")
            previousIndex = index
        }
    }
}

final class AnalysisProgressTrackerTests: XCTestCase {
    func testStartsWithNoCurrentStage() {
        let tracker = AnalysisProgressTracker()
        XCTAssertNil(tracker.currentStage)
        XCTAssertTrue(tracker.stageHistory.isEmpty)
    }

    func testPipelineDidStartRecordsHistoryAndCurrentStage() {
        let tracker = AnalysisProgressTracker()

        tracker.pipelineDidStart(stage: .ingestion)
        XCTAssertEqual(tracker.currentStage, .mappingRepositoryStructure)
        XCTAssertEqual(tracker.stageHistory.map(\.stage), [.ingestion])

        tracker.pipelineDidStart(stage: .assembly)
        XCTAssertEqual(tracker.currentStage, .buildingArchitecture)
        XCTAssertEqual(tracker.stageHistory.map(\.stage), [.ingestion, .assembly])
    }

    func testPipelineDidStartIsSafeFromConcurrentCallers() {
        // Mirrors the shape AnalysisRunner actually uses it in: OrionCodeIntel.AnalysisPipeline
        // calls this synchronously from a single background task, but the lock exists precisely
        // so that isn't an assumption this test just takes on faith.
        let tracker = AnalysisProgressTracker()
        let stages = PipelineStageID.allCases
        let group = DispatchGroup()
        for stage in stages {
            group.enter()
            DispatchQueue.global().async {
                tracker.pipelineDidStart(stage: stage)
                group.leave()
            }
        }
        group.wait()
        XCTAssertEqual(tracker.stageHistory.count, stages.count)
    }
}
