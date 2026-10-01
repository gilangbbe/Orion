import XCTest

/// Docs/19 M6, redone for the M8 redesign: a new conversation's starter questions, one question
/// asked from the composer, and the answer, screenshotted. Needs a repository imported into the
/// simulator, and the host Mac's Apple Intelligence for the model; without it the screenshot shows
/// Ask's unavailable state instead.
final class AskWalkthroughUITests: XCTestCase {
    func testAskOneQuestion() throws {
        let app = XCUIApplication()
        app.launch()
        app.tabBars.buttons["Ask"].firstMatch.tap()
        sleep(2)
        let newConversation = app.buttons["New Conversation"].firstMatch
        if newConversation.waitForExistence(timeout: 3) { newConversation.tap() }
        sleep(1)
        snap(app, "1-ask")

        let field = app.textFields.firstMatch
        guard field.waitForExistence(timeout: 5) else {
            throw XCTSkip("Ask isn't available here (no repository, or no on-device model)")
        }
        field.tap()
        field.typeText("Where is the Router class defined, and what does add_route do?")
        app.buttons["ask.send"].firstMatch.tap()
        sleep(3)
        snap(app, "2-asking")
        let thinking = app.staticTexts["Looking through the repository…"]
        for _ in 0..<60 where thinking.exists { sleep(2) }
        sleep(3)
        snap(app, "3-answer")

        // The conversations list, one step back on iPhone.
        app.navigationBars.firstMatch.buttons.element(boundBy: 0).tap()
        sleep(1)
        snap(app, "4-conversations")
    }

    private func snap(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
