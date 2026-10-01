import XCTest

/// Docs/19 M7, redone for the M8 redesign: practises one concept in the simulator -- the concept
/// list, an on-device drafted (or shipped) question, an answer, the graded breakdown -- and
/// screenshots each step. Needs a repository imported into the simulator, and the host Mac's Apple
/// Intelligence for the model.
final class LearnWalkthroughUITests: XCTestCase {
    func testPractiseOneConcept() throws {
        let app = XCUIApplication()
        app.launch()
        app.tabBars.buttons["Learn"].firstMatch.tap()
        sleep(2)
        snap(app, "1-concepts")

        let concepts = app.buttons.matching(identifier: "learn.concept")
        // At large text sizes the list starts below the fold.
        for _ in 0..<6 where !concepts.firstMatch.exists { app.swipeUp() }
        guard concepts.firstMatch.waitForExistence(timeout: 5) else {
            throw XCTSkip("Learn isn't available here (no repository, no concepts, or no on-device model)")
        }

        // The device can't keep every draft (its verifier refuses questions resting on contradicted
        // knowledge), so try the top few concepts until one has a question.
        var found = false
        for index in 0..<min(5, concepts.count) {
            app.buttons.matching(identifier: "learn.concept").element(boundBy: index).tap()
            sleep(1)
            if index == 0 { snap(app, "2-practice") }
            if app.buttons["learn.depth.1"].firstMatch.waitForExistence(timeout: 2) {
                app.buttons["learn.depth.1"].firstMatch.tap()
                let writing = app.staticTexts["Writing a recall question on this iPhone…"]
                for _ in 0..<45 where writing.exists { sleep(2) }
            }
            if answerField(app).waitForExistence(timeout: 3) {
                found = true
                break
            }
            snap(app, "2b-no-question-\(index)")
            app.navigationBars.firstMatch.buttons.element(boundBy: 0).tap()
            sleep(1)
        }
        guard found else { throw XCTSkip("no concept produced a question on this model") }
        snap(app, "3-question")

        let field = answerField(app)
        field.tap()
        field.typeText("It matches the incoming request against the registered routes in order and hands it to the first one that fully matches.")
        app.buttons["learn.check"].firstMatch.tap()
        sleep(3)
        snap(app, "4-grading")
        for _ in 0..<90 where !app.buttons["Another Question"].exists { sleep(2) }
        sleep(1)
        snap(app, "5-graded")
        app.swipeUp()
        sleep(1)
        snap(app, "6-graded-more")
    }

    /// A vertical `TextField` can surface as a text field or a text view.
    private func answerField(_ app: XCUIApplication) -> XCUIElement {
        let field = app.textFields["learn.answer"].firstMatch
        return field.exists ? field : app.textViews["learn.answer"].firstMatch
    }

    private func snap(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
