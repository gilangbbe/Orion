import OrionCodeIntel
import XCTest

@testable import Orion

/// Docs/14_phase4_5_ui_ux_redesign.md §8 M8's own testing plan: a regression test confirming a
/// second Ask/analysis overwrites rather than accumulates -- the same shape of test Docs/13 M2
/// used for the SQLite reopen-crash fix, pinning §7 Decision 2 ("last-only, never a rolling log").
final class DiagnosticsSessionTests: XCTestCase {
    func testRecordAskOverwritesRatherThanAccumulates() {
        let session = DiagnosticsSession()
        let first = AskResultSummary(
            answerText: "first answer", depth: 1, routingMethod: "heuristic",
            routingConfidence: "high", rationale: "r1", outcome: "verified", claimCount: 0,
            droppedClaimCount: 0, partial: false)
        let second = AskResultSummary(
            answerText: "second answer", depth: 2, routingMethod: "heuristic",
            routingConfidence: "medium", rationale: "r2", outcome: "verified", claimCount: 1,
            droppedClaimCount: 0, partial: false)

        session.recordAsk(question: "Question one", outcome: .answered(first))
        session.recordAsk(question: "Question two", outcome: .answered(second))

        XCTAssertEqual(session.lastAskTrace?.question, "Question two")
        XCTAssertEqual(session.lastAskTrace?.summary, second)
    }

    func testRecordAskWithAFailedOutcomeLeavesThePreviousTraceInPlace() {
        let session = DiagnosticsSession()
        let summary = AskResultSummary(
            answerText: "answer", depth: 1, routingMethod: "heuristic", routingConfidence: "high",
            rationale: "r", outcome: "verified", claimCount: 0, droppedClaimCount: 0, partial: false)

        session.recordAsk(question: "Question one", outcome: .answered(summary))
        session.recordAsk(question: "Question two", outcome: .failed("boom"))

        XCTAssertEqual(session.lastAskTrace?.question, "Question one")
        XCTAssertEqual(session.lastAskTrace?.summary, summary)
    }

    func testRecordAskWithNoPriorTraceLeavesItNilOnFailure() {
        let session = DiagnosticsSession()
        session.recordAsk(question: "Question one", outcome: .failed("boom"))
        XCTAssertNil(session.lastAskTrace)
    }

    func testRecordAnalysisOverwritesRatherThanAccumulates() {
        let session = DiagnosticsSession()
        session.recordAnalysis(stageHistory: [(.ingestion, Date())])
        session.recordAnalysis(stageHistory: [(.ast, Date()), (.symbols, Date())])

        XCTAssertEqual(session.lastAnalysisStages?.map(\.stage), [.ast, .symbols])
    }
}
