import XCTest

@testable import Orion

/// Docs/14_phase4_5_ui_ux_redesign.md §8 M8.6's own testing plan: `MarkdownText.attributed(_:)` is
/// the one pure, testable surface behind the view (no ViewInspector-style tool in this codebase to
/// assert on rendered `Text` content directly).
final class MarkdownTextTests: XCTestCase {
    func testBoldMarkersProduceAStronglyEmphasizedRunNotLiteralAsterisks() {
        let attributed = MarkdownText.attributed("This is **bold** text.")

        XCTAssertEqual(String(attributed.characters), "This is bold text.")
        let boldRun = attributed.runs.first { $0.inlinePresentationIntent == .stronglyEmphasized }
        XCTAssertNotNil(boldRun)
    }

    func testPlainTextWithNoMarkdownIsUnchanged() {
        let attributed = MarkdownText.attributed("Just plain text.")
        XCTAssertEqual(String(attributed.characters), "Just plain text.")
    }

    func testPreservesBlankLinesBetweenParagraphs() {
        // .inlineOnlyPreservingWhitespace's whole reason for being here, not .full's default:
        // `Text` has no way to re-render block-element spacing, so paragraph breaks must survive
        // as literal characters instead.
        let attributed = MarkdownText.attributed("Line one.\n\nLine two.")
        XCTAssertEqual(String(attributed.characters), "Line one.\n\nLine two.")
    }

    func testEmptyStringDoesNotThrowOrCrash() {
        XCTAssertEqual(String(MarkdownText.attributed("").characters), "")
    }
}
