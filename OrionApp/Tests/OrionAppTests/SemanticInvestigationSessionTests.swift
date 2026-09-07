import XCTest

@testable import Orion

final class SemanticInvestigationSessionTests: XCTestCase {
    func testInitialStateIsIdle() {
        XCTAssertEqual(SemanticInvestigationSession().state, .idle)
    }

    func testBeginReachesInvestigating() {
        let session = SemanticInvestigationSession()
        session.begin()
        XCTAssertEqual(session.state, .investigating)
    }

    func testSucceededReachesCompletedWithSummary() {
        let session = SemanticInvestigationSession()
        session.begin()
        let summary = SemanticInvestigationSummary.stub(outcome: "verified", componentCount: 3)
        session.succeeded(summary)
        XCTAssertEqual(session.state, .completed(summary))
    }

    func testFailedReachesFailedWithMessage() {
        let session = SemanticInvestigationSession()
        session.begin()
        session.failed("claude not found")
        XCTAssertEqual(session.state, .failed("claude not found"))
    }

    func testResetReturnsToIdle() {
        let session = SemanticInvestigationSession()
        session.begin()
        session.failed("boom")
        session.reset()
        XCTAssertEqual(session.state, .idle)
    }
}

extension SemanticInvestigationSummary {
    /// A synthetic summary for tests that don't need a real `SemanticIngestOutcome` (there is no
    /// public initializer from raw fields -- the real one only ever builds from a genuine
    /// ingest result, on purpose, so nothing in the app can fabricate one call-site conveniently
    /// and accidentally use it for real). Test-only, kept next to the state-machine tests that
    /// need it.
    fileprivate static func stub(outcome: String, componentCount: Int) -> SemanticInvestigationSummary {
        SemanticInvestigationSummary(
            outcomeForTesting: outcome, componentCount: componentCount, droppedComponentCount: 0,
            duplicateComponentCount: 0, componentRelationshipCount: 0,
            unconfirmedComponentRelationshipCount: 0, droppedComponentRelationshipCount: 0,
            claimCount: 0, contradictedClaimCount: 0, droppedClaimCount: 0, totalCostUsd: nil,
            numTurns: nil, durationMs: nil)
    }
}
