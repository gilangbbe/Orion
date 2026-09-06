import XCTest

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
}
