import XCTest
@testable import OrionCodeIntel

final class ModelTests: XCTestCase {

    func testVersionIsSemver() {
        let parts = OrionCodeIntel.version.split(separator: ".")
        XCTAssertEqual(parts.count, 3, "version should be MAJOR.MINOR.PATCH")
        XCTAssertTrue(parts.allSatisfy { Int($0) != nil })
    }

    func testEpistemicVocabularyMatchesDocs04() {
        // Resolved open question #5: Docs/04 vocabulary wins.
        XCTAssertEqual(
            Set(EpistemicType.allCases.map(\.rawValue)),
            ["FACT", "INTERPRETATION", "INFERENCE", "UNKNOWN", "CONTRADICTED"]
        )
    }

    func testConfidenceTierScores() {
        XCTAssertEqual(ConfidenceTier.high.score, 0.9)
        XCTAssertEqual(ConfidenceTier.unresolved.score, 0.1)
    }

    func testRelationshipRawValuesUseSnakeCase() {
        XCTAssertEqual(RelationshipType.dependsOn.rawValue, "depends_on")
        XCTAssertEqual(RelationshipType.testedBy.rawValue, "tested_by")
        XCTAssertEqual(RelationshipType.partOf.rawValue, "part_of")
    }

    func testSourceLanguageMapsExtensions() {
        XCTAssertEqual(SourceLanguage(fileExtension: "PY"), .python)
        XCTAssertEqual(SourceLanguage(fileExtension: "pyi"), .python)
        XCTAssertNil(SourceLanguage(fileExtension: "swift"))
    }

    func testRegistryResolvesPython() throws {
        let support = try LanguageRegistry().support(for: .python)
        XCTAssertEqual(support.language, .python)
        XCTAssertEqual(support.symbolQueryName, "python-symbols")
    }
}
