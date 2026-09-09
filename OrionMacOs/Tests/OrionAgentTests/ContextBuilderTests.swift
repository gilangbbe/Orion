import XCTest
import OrionCodeIntel

@testable import OrionAgent

final class ContextBuilderTests: XCTestCase {

    private var keepAlive: [TempDir] = []

    func testReturnsNilWhenExportDirectoryIsEmpty() throws {
        let dir = try TempDir()
        keepAlive.append(dir)
        XCTAssertNil(ContextBuilder.build(exportDir: dir.url))
    }

    func testIncludesCodeGraphWhenPresent() throws {
        let dir = try TempDir()
        keepAlive.append(dir)
        try dir.write("code_graph.json", #"{"repository": {"commit_hash": "abc123"}}"#)

        let context = try XCTUnwrap(ContextBuilder.build(exportDir: dir.url))
        XCTAssertTrue(context.contains("abc123"))
        XCTAssertTrue(context.contains("Code Graph"))
    }

    func testIncludesSemanticModelWhenPresent() throws {
        let dir = try TempDir()
        keepAlive.append(dir)
        try dir.write("semantic_model.json", #"{"investigation_id": "inv-1"}"#)

        let context = try XCTUnwrap(ContextBuilder.build(exportDir: dir.url))
        XCTAssertTrue(context.contains("inv-1"))
        XCTAssertTrue(context.contains("Semantic model"))
    }

    func testTruncatesOversizedFiles() throws {
        let dir = try TempDir()
        keepAlive.append(dir)
        try dir.write("code_graph.json", String(repeating: "x", count: 30_000))

        let context = try XCTUnwrap(ContextBuilder.build(exportDir: dir.url))
        XCTAssertTrue(context.contains("...(truncated)"))
        XCTAssertLessThan(context.count, 25_000)
    }

    // MARK: Docs/15 §4.3 -- session context threading

    /// Regression guard for the M3 signature change: an empty `priorTurns` (every pre-Phase-5
    /// call site's implicit default) must produce byte-identical output to what this function
    /// always returned.
    func testEmptyPriorTurnsAndNilComponentContextMatchPrePhase5Output() throws {
        let dir = try TempDir()
        keepAlive.append(dir)
        try dir.write("code_graph.json", #"{"repository": {"commit_hash": "abc123"}}"#)

        let withDefaults = ContextBuilder.build(exportDir: dir.url)
        let explicitlyEmpty = ContextBuilder.build(
            exportDir: dir.url, priorTurns: [], componentContext: nil)
        XCTAssertEqual(withDefaults, explicitlyEmpty)
    }

    func testIncludesPriorTurnsOldestFirst() throws {
        let dir = try TempDir()
        keepAlive.append(dir)
        let turns = [
            AskSessionPriorTurn(question: "What does Router do?", answerText: "It dispatches.", outcome: "verified"),
            AskSessionPriorTurn(question: "And what calls it?", answerText: "Starlette.__call__.", outcome: "verified"),
        ]

        let context = try XCTUnwrap(ContextBuilder.build(exportDir: dir.url, priorTurns: turns))
        XCTAssertTrue(context.contains("Conversation so far"))
        let firstRange = try XCTUnwrap(context.range(of: "What does Router do?"))
        let secondRange = try XCTUnwrap(context.range(of: "And what calls it?"))
        XCTAssertTrue(firstRange.lowerBound < secondRange.lowerBound, "turns must render oldest first")
        XCTAssertTrue(context.contains("It dispatches."))
        XCTAssertTrue(context.contains("outcome: verified"))
    }

    func testTruncatesAnOversizedPriorAnswer() throws {
        let dir = try TempDir()
        keepAlive.append(dir)
        let turns = [
            AskSessionPriorTurn(
                question: "Explain everything.", answerText: String(repeating: "y", count: 30_000),
                outcome: "verified")
        ]
        let context = try XCTUnwrap(ContextBuilder.build(exportDir: dir.url, priorTurns: turns))
        XCTAssertTrue(context.contains("...(truncated)"))
    }

    func testIncludesComponentContextWhenPresent() throws {
        let dir = try TempDir()
        keepAlive.append(dir)
        let context = try XCTUnwrap(
            ContextBuilder.build(exportDir: dir.url, componentContext: "Component: Authentication"))
        XCTAssertTrue(context.contains("focused on one specific component"))
        XCTAssertTrue(context.contains("Component: Authentication"))
    }

    func testEmptyComponentContextStringIsOmitted() throws {
        let dir = try TempDir()
        keepAlive.append(dir)
        try dir.write("code_graph.json", #"{"repository": {"commit_hash": "abc123"}}"#)
        let context = try XCTUnwrap(ContextBuilder.build(exportDir: dir.url, componentContext: ""))
        XCTAssertFalse(context.contains("focused on one specific component"))
    }
}
