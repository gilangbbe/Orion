import XCTest

@testable import Orion

/// Docs/14_phase4_5_ui_ux_redesign.md §8 M4's own testing plan: the grouping/search behavior
/// behind Ask's master-detail list, and the "Ask about {name}" hand-off actually producing a
/// tagged entry -- all pure logic on `AskHistory`, independent of `AskView`/`ComponentDetailView`
/// themselves.
final class AskHistoryTests: XCTestCase {
    func testAskInsertsAtTheFrontAndSelectsIt() {
        let history = AskHistory()
        let firstID = history.ask("What does NetworkClient do?")
        let secondID = history.ask("What does SessionStore do?")

        XCTAssertEqual(history.entries.map(\.id), [secondID, firstID])
        XCTAssertEqual(history.selectedID, secondID)
    }

    func testResolveUpdatesOnlyTheMatchingEntry() {
        let history = AskHistory()
        let firstID = history.ask("Question one")
        let secondID = history.ask("Question two")

        history.resolve(secondID, outcome: .failed("boom"))

        XCTAssertNil(history.entries.first { $0.id == firstID }?.outcome)
        XCTAssertEqual(history.entries.first { $0.id == secondID }?.outcome, .failed("boom"))
    }

    func testResolveIgnoresAnUnknownID() {
        let history = AskHistory()
        history.ask("Question one")
        history.resolve(UUID(), outcome: .failed("no such entry"))
        XCTAssertNil(history.entries.first?.outcome)
    }

    func testGroupsDefaultUntaggedQuestionsToGeneral() {
        let history = AskHistory()
        history.ask("Untagged question")

        let groups = history.groups(matching: "")

        XCTAssertEqual(groups.map(\.name), ["General"])
        XCTAssertEqual(groups.first?.entries.count, 1)
    }

    func testGroupsSortAlphabeticallyWithGeneralAlwaysLast() {
        let history = AskHistory()
        history.ask("Untagged question")
        history.ask("About SessionStore", component: "SessionStore")
        history.ask("About Authentication", component: "Authentication")

        let groups = history.groups(matching: "")

        XCTAssertEqual(groups.map(\.name), ["Authentication", "SessionStore", "General"])
    }

    func testGroupsFilterByCaseInsensitiveSubstringMatch() {
        let history = AskHistory()
        history.ask("What does NetworkClient do?", component: "NetworkClient")
        history.ask("What does SessionStore do?", component: "SessionStore")

        let groups = history.groups(matching: "networkclient")

        XCTAssertEqual(groups.map(\.name), ["NetworkClient"])
        XCTAssertEqual(groups.first?.entries.map(\.question), ["What does NetworkClient do?"])
    }

    func testGroupsOmitGroupsWithNoMatchesRatherThanShowingThemEmpty() {
        let history = AskHistory()
        history.ask("About Authentication", component: "Authentication")
        history.ask("About SessionStore", component: "SessionStore")

        let groups = history.groups(matching: "does not exist anywhere")

        XCTAssertTrue(groups.isEmpty)
    }

    func testGroupsWithBlankSearchReturnsEverything() {
        let history = AskHistory()
        history.ask("About Authentication", component: "Authentication")
        history.ask("Untagged question")

        let groups = history.groups(matching: "   ")

        XCTAssertEqual(Set(groups.map(\.name)), ["Authentication", "General"])
    }

    // MARK: - "Ask about {name}" hand-off (Docs/14 §4.5/§8 M8.5 item 6)

    func testPendingScopeStartsNil() {
        XCTAssertNil(AskHistory().pendingScope)
    }

    func testAskingWithThePendingScopeAsTheComponentProducesAGroupedEntry() {
        let history = AskHistory()
        history.pendingScope = "Authentication"

        let id = history.ask("What does it actually validate?", component: history.pendingScope)

        XCTAssertEqual(history.entries.first?.id, id)
        XCTAssertEqual(history.entries.first?.component, "Authentication")
        XCTAssertEqual(history.groups(matching: "").map(\.name), ["Authentication"])
    }

    func testAskClearsThePendingScopeRegardlessOfWhetherItWasUsed() {
        let history = AskHistory()
        history.pendingScope = "Authentication"

        history.ask("A totally unrelated general question")

        XCTAssertNil(history.pendingScope)
    }

    func testClearingThePendingScopeExplicitlyLeavesTheNextQuestionGeneral() {
        let history = AskHistory()
        history.pendingScope = "Authentication"

        history.pendingScope = nil
        history.ask("Some question")

        XCTAssertNil(history.entries.first?.component)
        XCTAssertEqual(history.groups(matching: "").map(\.name), ["General"])
    }
}
