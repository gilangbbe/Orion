import XCTest

@testable import OrionAgent

/// The six worked examples are lifted verbatim from
/// Docs/03_agent_and_model_routing.md §2 -- a small, high-signal, zero-cost check that the
/// heuristic classifier agrees with the document that defines it.
final class DepthHeuristicsTests: XCTestCase {

    // MARK: L1

    func testWhatDoesXDo() {
        assertDepth(1, "What does `AuthService` do?")
    }

    func testWhichFilesBelongToThisComponent() {
        assertDepth(1, "Which files belong to this component?")
    }

    func testWhatIsTheResponsibilityOfThisClass() {
        assertDepth(1, "What is the responsibility of this class?")
    }

    // MARK: L2

    func testWhichComponentsDependOnAuthService() {
        assertDepth(2, "Which components depend on `AuthService`?")
    }

    func testWhereIsThisDataPersisted() {
        assertDepth(2, "Where is this data persisted?")
    }

    func testWhatTestsCoverThisComponent() {
        assertDepth(2, "What tests cover this component?")
    }

    // MARK: Non-matches fall through to the fallback classifier

    func testAmbiguousArchitecturalQuestionDoesNotMatchAnyHeuristic() {
        XCTAssertNil(
            DepthHeuristics.classify(
                "Why was the authentication architecture designed this way?"))
    }

    func testChangeImpactQuestionDoesNotMatchAnyHeuristic() {
        XCTAssertNil(
            DepthHeuristics.classify(
                "What would happen if the authentication provider were replaced?"))
    }

    // MARK: Every heuristic hit reports high confidence via the heuristic method

    func testHeuristicMatchIsAlwaysHighConfidence() {
        let decision = DepthHeuristics.classify("What does `Router` do?")
        XCTAssertEqual(decision?.confidence, .high)
        XCTAssertEqual(decision?.method, .heuristic)
    }

    private func assertDepth(
        _ expected: Int, _ question: String, file: StaticString = #filePath, line: UInt = #line
    ) {
        guard let decision = DepthHeuristics.classify(question) else {
            XCTFail("expected a heuristic match for \"\(question)\"", file: file, line: line)
            return
        }
        XCTAssertEqual(decision.depth, expected, "for question: \(question)", file: file, line: line)
        XCTAssertEqual(decision.confidence, .high, file: file, line: line)
        XCTAssertEqual(decision.method, .heuristic, file: file, line: line)
    }
}
