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

    // MARK: blocks(_:) -- a real reported bug: `.inlineOnlyPreservingWhitespace` (above) left a
    // real depth-3 answer's `###` headers, `---` thematic breaks, and numbered/bulleted lists
    // showing their literal markdown characters instead of being rendered. `MarkdownText`'s view
    // now renders through `blocks(_:)` instead for exactly that reason.

    func testHeaderProducesAHeadingBlockWithTheLiteralHashesStripped() {
        guard case .heading(let level, let text) = MarkdownText.blocks("### Core Features").first else {
            return XCTFail("expected a .heading block")
        }
        XCTAssertEqual(level, 3)
        XCTAssertEqual(String(text.characters), "Core Features")
    }

    func testThematicBreakProducesItsOwnBlock() {
        let blocks = MarkdownText.blocks("Above.\n\n---\n\nBelow.")
        XCTAssertTrue(blocks.contains(.thematicBreak), "expected a .thematicBreak block, got \(blocks)")
    }

    func testOrderedListItemsCarryTheirRealOrdinalAndMarkThemselvesOrdered() {
        let blocks = MarkdownText.blocks("1. First\n2. Second")
        let ordinals = blocks.compactMap { block -> Int? in
            guard case .listItem(let ordered, let ordinal, _, _) = block, ordered else { return nil }
            return ordinal
        }
        XCTAssertEqual(ordinals, [1, 2])
    }

    func testUnorderedListItemIsNotMarkedOrdered() {
        guard case .listItem(let ordered, _, _, let text) = MarkdownText.blocks("- a bullet").first else {
            return XCTFail("expected a .listItem block")
        }
        XCTAssertFalse(ordered)
        XCTAssertEqual(String(text.characters), "a bullet")
    }

    func testBoldInsideAHeaderIsStillResolvedNotLiteralAsterisks() {
        guard case .heading(_, let text) = MarkdownText.blocks("## **Bold** Header").first else {
            return XCTFail("expected a .heading block")
        }
        XCTAssertEqual(String(text.characters), "Bold Header")
        XCTAssertNotNil(text.runs.first { $0.inlinePresentationIntent == .stronglyEmphasized })
    }

    func testPlainParagraphWithNoBlockMarkupIsStillAParagraphBlock() {
        guard case .paragraph(let text) = MarkdownText.blocks("Just plain text.").first else {
            return XCTFail("expected a .paragraph block")
        }
        XCTAssertEqual(String(text.characters), "Just plain text.")
    }

    func testEmptyStringProducesNoBlocks() {
        XCTAssertEqual(MarkdownText.blocks(""), [])
    }
}
