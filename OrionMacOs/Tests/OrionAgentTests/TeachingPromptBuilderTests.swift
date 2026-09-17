import XCTest
import OrionCodeIntel
@testable import OrionAgent

/// Docs/17 M2: `TeachingPromptBuilder` is pure string assembly — no `Store`, no model.
final class TeachingPromptBuilderTests: XCTestCase {

    private func inputs(band: Int, related: [String] = [], priorReasons: [String] = [])
        -> TeachingPromptInputs
    {
        TeachingPromptInputs(
            conceptId: "concept-42", conceptKind: "component", conceptLabel: "Routing",
            band: band, evidenceLines: ["m/a.py::Router — class Router", "m/a.py::Route — class Route"],
            relatedConceptLabels: related, priorRejectionReasons: priorReasons)
    }

    func testCarriesConceptIdBandAndSchemaHint() {
        let p = TeachingPromptBuilder.build(inputs(band: 1))
        XCTAssertTrue(p.contains("concept-42"))
        XCTAssertTrue(p.contains("difficulty_band must be 1"))
        XCTAssertTrue(p.contains(TeachingSchema.currentVersion))
        XCTAssertTrue(p.contains("\"schema_version\""))   // promptHint embedded
        XCTAssertTrue(p.contains("m/a.py::Router — class Router"))
    }

    func testBandGuidanceMatchesBand() {
        XCTAssertTrue(TeachingPromptBuilder.build(inputs(band: 1)).contains("RECALL"))
        XCTAssertTrue(TeachingPromptBuilder.build(inputs(band: 2)).contains("COMPREHENSION"))
        XCTAssertTrue(TeachingPromptBuilder.build(inputs(band: 3)).contains("TRANSFER"))
    }

    func testRelatedConceptsOnlyShownForBandTwoPlus() {
        XCTAssertFalse(TeachingPromptBuilder.build(inputs(band: 1, related: ["Middleware"]))
            .contains("Neighbouring concepts"))
        XCTAssertTrue(TeachingPromptBuilder.build(inputs(band: 2, related: ["Middleware"]))
            .contains("Middleware"))
    }

    func testPriorRejectionReasonsAppendedOnRetry() {
        let p = TeachingPromptBuilder.build(inputs(band: 1, priorReasons: ["anchor X did not resolve"]))
        XCTAssertTrue(p.contains("previous attempt was REJECTED"))
        XCTAssertTrue(p.contains("anchor X did not resolve"))
    }
}
