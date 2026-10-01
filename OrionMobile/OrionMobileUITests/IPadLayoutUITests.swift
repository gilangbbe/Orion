import XCTest

/// Docs/19 M8: the iPad layout -- each tab's split view, with something selected -- screenshotted.
/// A visual check, run on an iPad simulator holding a repository; skipped on iPhone.
final class IPadLayoutUITests: XCTestCase {
    func testIPadLayout() throws {
        let app = XCUIApplication()
        app.launch()
        guard app.windows.firstMatch.frame.width > 700 else { throw XCTSkip("iPad layout check") }
        sleep(2)

        tab(app, "Explore")
        let component = app.buttons["explore.component"].firstMatch
        guard component.waitForExistence(timeout: 10) else { throw XCTSkip("import a snapshot first") }
        sleep(3)
        snap(app, "1-explore-map")
        component.tap()
        sleep(2)
        snap(app, "2-explore-component")

        tab(app, "Ask")
        sleep(2)
        snap(app, "3-ask")

        tab(app, "Learn")
        let concept = app.buttons["learn.concept"].firstMatch
        if concept.waitForExistence(timeout: 5) {
            concept.tap()
            sleep(2)
        }
        snap(app, "4-learn")

        tab(app, "Library")
        sleep(1)
        snap(app, "5-library")
    }

    /// The tab bar on iPad sits at the top, or becomes a sidebar.
    private func tab(_ app: XCUIApplication, _ name: String) {
        let tab = app.tabBars.buttons[name].firstMatch
        if tab.exists {
            tab.tap()
        } else {
            app.buttons[name].firstMatch.tap()
        }
    }

    private func snap(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
