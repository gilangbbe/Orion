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
