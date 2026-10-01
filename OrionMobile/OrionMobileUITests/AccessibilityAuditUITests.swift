import XCTest

/// Docs/19 M8: Xcode's accessibility audit (missing labels, contrast, hit areas, clipped Dynamic
/// Type text, …) on each main screen. Needs a repository in the simulator, like the walkthroughs.
/// Each issue is recorded with its screen; the test fails if any remain.
final class AccessibilityAuditUITests: XCTestCase {
    private var app: XCUIApplication!
    private var issues: [String] = []

    override func setUpWithError() throws {
        continueAfterFailure = true
        app = XCUIApplication()
        app.launch()
    }

    func testMainScreensPassTheAccessibilityAudit() throws {
        app.tabBars.buttons["Explore"].firstMatch.tap()
        guard app.buttons["Map"].firstMatch.waitForExistence(timeout: 10) else {
            throw XCTSkip("import a snapshot into the simulator first")
        }
        audit("Explore")

        app.buttons["explore.component"].firstMatch.tap()
        sleep(2)
        audit("Component")
        app.navigationBars.firstMatch.buttons.element(boundBy: 0).tap()

        app.tabBars.buttons["Ask"].firstMatch.tap()
        sleep(2)
        audit("Ask")

        app.tabBars.buttons["Learn"].firstMatch.tap()
        sleep(2)
        audit("Learn")
        let concept = app.buttons["learn.concept"].firstMatch
        if concept.waitForExistence(timeout: 5) {
            concept.tap()
            sleep(2)
            audit("Practice")
            app.navigationBars.firstMatch.buttons.element(boundBy: 0).tap()
        }

        app.tabBars.buttons["Library"].firstMatch.tap()
        sleep(1)
        audit("Library")

        let report = issues.joined(separator: "\n")
        let attachment = XCTAttachment(string: report.isEmpty ? "no issues" : report)
        attachment.name = "accessibility-audit"
        attachment.lifetime = .keepAlways
        add(attachment)
        XCTAssertTrue(issues.isEmpty, report)
    }

    private func audit(_ screen: String) {
        do {
            try app.performAccessibilityAudit { issue in
                self.issues.append(
                    "[\(screen)] \(issue.auditType): \(issue.compactDescription) -- \(issue.element?.debugDescription.prefix(160) ?? "no element")")
                return true  // record, don't fail here; the test fails once at the end with the full list
            }
        } catch {
            issues.append("[\(screen)] audit failed: \(error)")
        }
    }
}
