import FoundationModels
import XCTest

@testable import OrionAgent

/// Offline coverage for `AppleFoundationDepthClassifier`'s OS 27 error mapping (Docs/18 M0) --
/// the error values are built through their public initializers, so no live model is needed.
final class AppleFoundationDepthClassifierTests: XCTestCase {

    private func assertEscalates(
        _ error: any Error, mentioning fragment: String, file: StaticString = #filePath, line: UInt = #line
    ) {
        guard let decision = AppleFoundationDepthClassifier.escalation(for: error, systemModel: "Core 3") else {
            return XCTFail("expected an escalation for \(error)", file: file, line: line)
        }
        XCTAssertEqual(decision.depth, 3, file: file, line: line)
        XCTAssertEqual(decision.confidence, .low, file: file, line: line)
        XCTAssertEqual(decision.method, .model, file: file, line: line)
        XCTAssertTrue(decision.isInScope, "a failed classification must never read as a decline", file: file, line: line)
        XCTAssertTrue(decision.rationale.contains(fragment), decision.rationale, file: file, line: line)
        XCTAssertTrue(decision.rationale.hasSuffix("(system model: Core 3)"), decision.rationale, file: file, line: line)
    }

    func testLanguageModelErrorsEscalateToDepth3() {
        assertEscalates(
            LanguageModelError.contextSizeExceeded(.init(contextSize: 4096, tokenCount: 5000, debugDescription: "")),
            mentioning: "5000 of 4096 tokens")
        assertEscalates(
            LanguageModelError.guardrailViolation(.init(debugDescription: "")), mentioning: "guardrails")
        assertEscalates(
            LanguageModelError.refusal(.init(explanation: "no", debugDescription: "")), mentioning: "refused")
        assertEscalates(
            LanguageModelError.unsupportedLanguageOrLocale(.init(languageCode: .init("xx"), debugDescription: "")),
            mentioning: "language")
        assertEscalates(
            LanguageModelError.rateLimited(.init(resetDate: nil, debugDescription: "")), mentioning: "rate limited")
        assertEscalates(LanguageModelError.timeout(.init(debugDescription: "")), mentioning: "timed out")
        assertEscalates(
            LanguageModelError.unsupportedGenerationGuide(.init(schemaName: nil, debugDescription: "")),
            mentioning: "does not support")
    }

    func testMissingAssetsEscalateToDepth3() {
        assertEscalates(
            SystemLanguageModel.Error.assetsUnavailable(.init(debugDescription: "")), mentioning: "assets")
    }

    func testNonFoundationModelsErrorIsNotSwallowed() {
        XCTAssertNil(AppleFoundationDepthClassifier.escalation(for: CancellationError(), systemModel: "Core 3"))
    }
}
