import XCTest

@testable import Orion

/// Docs/13_phase4_architecture_ui.md M6's own testing plan: "table-tested against all 5
/// vocabulary values, including that CONTRADICTED and UNKNOWN are never [rendered like FACT]."
final class EpistemicTagTests: XCTestCase {
    func testFromIsCaseInsensitiveForAllFiveVocabularyValues() {
        XCTAssertEqual(EpistemicTag.from("fact"), .fact)
        XCTAssertEqual(EpistemicTag.from("FACT"), .fact)
        XCTAssertEqual(EpistemicTag.from("Interpretation"), .interpretation)
        XCTAssertEqual(EpistemicTag.from("INFERENCE"), .inference)
        XCTAssertEqual(EpistemicTag.from("unknown"), .unknown)
        XCTAssertEqual(EpistemicTag.from("CONTRADICTED"), .contradicted)
    }

    func testFromFallsBackToUnknownForAnUnrecognizedValueRatherThanDefaultingToFact() {
        XCTAssertEqual(EpistemicTag.from("something_else"), .unknown)
        XCTAssertEqual(EpistemicTag.from(""), .unknown)
    }

    func testEveryTagHasANonEmptyLabelAndSystemImage() {
        for tag in EpistemicTag.allCases {
            XCTAssertFalse(tag.label.isEmpty, "\(tag) has no label")
            XCTAssertFalse(tag.systemImage.isEmpty, "\(tag) has no systemImage")
        }
    }

    /// Docs/04's hard rule ("the UI must not present inference as fact") checked directly, not
    /// just asserted in a comment: every non-FACT tag must differ from FACT in *both* color and
    /// icon, so no rendering path can make an inference/interpretation/unknown/contradicted
    /// claim visually indistinguishable from a checked fact.
    func testOnlyFactIsRenderedWithFactsOwnColorAndIcon() {
        for tag in EpistemicTag.allCases where tag != .fact {
            XCTAssertNotEqual(tag.color, EpistemicTag.fact.color, "\(tag) must not look like FACT")
            XCTAssertNotEqual(
                tag.systemImage, EpistemicTag.fact.systemImage, "\(tag) must not look like FACT")
        }
    }

    func testAllFiveTagsHaveDistinctColorsFromEachOther() {
        // A weaker "not equal to FACT" check alone would still allow two non-FACT tags (e.g.
        // INFERENCE and CONTRADICTED) to collide with each other.
        let tags = EpistemicTag.allCases
        for i in tags.indices {
            for j in tags.indices where j > i {
                XCTAssertNotEqual(
                    tags[i].color, tags[j].color,
                    "\(tags[i]) and \(tags[j]) must not share a color")
            }
        }
    }
}
