import XCTest

/// Docs/19 M4, redone for the M8 redesign: walks Explore on whatever library the simulator holds
/// and attaches a screenshot per screen -- a visual check, not a CI gate (it needs a repository
/// imported first, e.g. by copying an `.orionsnap` into the app's Documents with `simctl`). Skips
/// when the library is empty.
final class ExploreWalkthroughUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()
    }

    private func snap(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Scrolls until the element is on screen: at large text sizes rows start below the fold,
    /// and a lazy list doesn't create rows it hasn't shown.
    @discardableResult
    private func reveal(_ element: XCUIElement) -> XCUIElement {
        for _ in 0..<10 where !(element.exists && element.isHittable) {
            app.swipeUp()
        }
        return element
    }

    private func back() {
        app.navigationBars.firstMatch.buttons.element(boundBy: 0).tap()
        sleep(1)
    }

    func testExploreWalkthrough() throws {
        app.tabBars.buttons["Library"].firstMatch.tap()
        guard app.navigationBars["Library"].waitForExistence(timeout: 5),
              !app.staticTexts["No Repositories Yet"].exists
        else { throw XCTSkip("import a snapshot into the simulator first") }
        snap("1-library")

        app.tabBars.buttons["Explore"].firstMatch.tap()
        sleep(3)
        snap("2-explore")

        let search = app.searchFields.firstMatch
        if search.waitForExistence(timeout: 2) {
            search.tap()
            search.typeText("rout")
            sleep(1)
            snap("3-search")
            app.buttons["Cancel"].firstMatch.tap()
            sleep(1)
        }

        reveal(app.buttons["Map"].firstMatch).tap()
        sleep(3)
        snap("4-map")
        back()

        // At large text sizes the components start below the fold, and a lazy list doesn't create
        // rows it hasn't shown.
        reveal(app.buttons["explore.component"].firstMatch).tap()
        sleep(2)
        snap("5-component")

        let member = app.buttons["component.member"].firstMatch
        if member.waitForExistence(timeout: 5) {
            member.tap()
            sleep(1)
            snap("6-evidence")
            app.buttons["Close"].firstMatch.tap()
            sleep(1)
        }
        app.swipeUp()
        app.swipeUp()
        sleep(1)
        snap("7-component-claims")
        back()

        reveal(app.buttons["Model Changes"].firstMatch).tap()
        sleep(1)
        snap("8-changes")
        let firstChange = app.collectionViews.firstMatch.cells.firstMatch
        if firstChange.waitForExistence(timeout: 3) {
            firstChange.tap()
            sleep(1)
            snap("9-change-detail")
        }
    }
}
