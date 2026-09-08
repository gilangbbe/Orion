import XCTest

@testable import Orion

/// Docs/14_phase4_5_ui_ux_redesign.md §8 M3's own testing plan: `InspectorContent`'s two cases are
/// mutually exclusive, and switching destinations closes whichever one is open.
final class AppShellStateTests: XCTestCase {
    private func sampleNode(id: String = "n1") -> ArchitectureNode {
        ArchitectureNode(
            id: id, name: "Authentication", subtitle: "Coordinates auth", size: 3,
            confidenceTier: "high", epistemicType: "INTERPRETATION")
    }

    func testInitialInspectorContentIsNil() {
        let state = AppShellState()
        XCTAssertNil(state.inspectorContent)
        XCTAssertEqual(state.destination, .overview)
    }

    func testSelectingANodeThenOpenQuestionsReplacesRatherThanStacks() {
        let state = AppShellState()
        state.inspectorContent = .node(sampleNode(), .structural(moduleCount: 3))
        state.inspectorContent = .openQuestions(["Is X still reachable?"])

        guard case .openQuestions(let questions) = state.inspectorContent else {
            return XCTFail("expected .openQuestions, got \(String(describing: state.inspectorContent))")
        }
        XCTAssertEqual(questions, ["Is X still reachable?"])
    }

    func testSelectingOpenQuestionsThenANodeReplacesRatherThanStacks() {
        let state = AppShellState()
        state.inspectorContent = .openQuestions(["Is X still reachable?"])
        let node = sampleNode()
        state.inspectorContent = .node(node, .structural(moduleCount: 3))

        guard case .node(let selected, _) = state.inspectorContent else {
            return XCTFail("expected .node, got \(String(describing: state.inspectorContent))")
        }
        XCTAssertEqual(selected, node)
    }

    func testChangingDestinationClosesAnOpenInspector() {
        let state = AppShellState()
        state.inspectorContent = .node(sampleNode(), .structural(moduleCount: 3))

        state.destination = .ask

        XCTAssertNil(state.inspectorContent, "leaving Overview must close the inspector")
        XCTAssertEqual(state.destination, .ask)
    }

    func testReselectingTheSameDestinationDoesNotDisturbAnOpenInspector() {
        // A no-op destination "change" (e.g. clicking the already-selected sidebar row) must not
        // wipe out whatever the inspector is showing.
        let state = AppShellState()
        state.destination = .overview
        state.inspectorContent = .openQuestions(["Is X still reachable?"])

        state.destination = .overview

        XCTAssertNotNil(state.inspectorContent)
    }
}
