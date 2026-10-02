import XCTest

/// A regression check (Docs/19 M8 follow-up): on iPhone, one Back from the open conversation must
/// land on the conversation list and stay there. It used to bounce straight into a new
/// conversation, so reaching the list took two Backs.
final class AskNavigationUITests: XCTestCase {
    func testOneBackReachesTheConversationListAndStays() throws {
        let app = XCUIApplication()
        app.launch()
        app.tabBars.buttons["Ask"].firstMatch.tap()
        let newConversation = app.buttons["New Conversation"].firstMatch
        guard newConversation.waitForExistence(timeout: 10) else {
            throw XCTSkip("Ask isn't available here (no repository)")
        }
        sleep(1)

        // Back, once.
        app.navigationBars.firstMatch.buttons.element(boundBy: 0).tap()
        sleep(2)

        // The list's title is the repository's name, with its title menu; the conversation's
        // composer must be gone -- and still gone a moment later.
        XCTAssertFalse(app.textFields.firstMatch.exists, "bounced back into a conversation")
        let list = app.collectionViews.firstMatch
        XCTAssertTrue(list.exists || app.staticTexts["No Conversations Yet"].exists, "not on the conversation list")
        sleep(2)
        XCTAssertFalse(app.textFields.firstMatch.exists, "bounced back into a conversation after a moment")
    }
}
