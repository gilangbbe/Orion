import XCTest

@testable import OrionAgent

final class EvidenceAnchorsTests: XCTestCase {

    func testExtractsAnchorFromToolArguments() {
        let calls = [
            ExecutedToolCall(
                turnIndex: 1, toolName: "callers",
                argumentsDescription: #"{"anchor":"pkg/router.py::Router"}"#,
                result: "No callers found for \"pkg/router.py::Router\".")
        ]
        XCTAssertEqual(EvidenceAnchors.extract(from: calls), ["pkg/router.py::Router"])
    }

    func testExtractsAnchorsFromToolResultLines() {
        let calls = [
            ExecutedToolCall(
                turnIndex: 1, toolName: "lookup_symbol",
                argumentsDescription: #"{"query":"Router"}"#,
                result: "pkg/router.py::Router (class) — pkg/router.py:3-6")
        ]
        XCTAssertEqual(EvidenceAnchors.extract(from: calls), ["pkg/router.py::Router", "pkg/router.py"])
    }

    func testDeduplicatesInFirstSeenOrder() {
        let calls = [
            ExecutedToolCall(
                turnIndex: 1, toolName: "lookup_symbol", argumentsDescription: "{}",
                result: "pkg/router.py::Router (class)"),
            ExecutedToolCall(
                turnIndex: 2, toolName: "callers",
                argumentsDescription: #"{"anchor":"pkg/router.py::Router"}"#,
                result: "calls: pkg/handlers.py::handle"),
        ]
        XCTAssertEqual(
            EvidenceAnchors.extract(from: calls),
            ["pkg/router.py::Router", "pkg/handlers.py::handle"])
    }

    func testNoAnchorShapedTextYieldsEmpty() {
        let calls = [
            ExecutedToolCall(
                turnIndex: 1, toolName: "lookup_symbol", argumentsDescription: #"{"query":"nope"}"#,
                result: "No symbols found matching \"nope\".")
        ]
        XCTAssertEqual(EvidenceAnchors.extract(from: calls), [])
    }

    func testEmptyToolCallsYieldsEmpty() {
        XCTAssertEqual(EvidenceAnchors.extract(from: []), [])
    }
}
