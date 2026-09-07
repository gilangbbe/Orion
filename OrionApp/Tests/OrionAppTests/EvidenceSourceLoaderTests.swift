import XCTest

@testable import Orion

final class EvidenceSourceLoaderTests: XCTestCase {
    private func makeRepoWithFile(_ relativePath: String, contents: String) throws -> URL {
        let repoRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("EvidenceSourceLoaderTests-\(UUID().uuidString)")
        let fileURL = repoRoot.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: fileURL, atomically: true, encoding: .utf8)
        return repoRoot
    }

    /// 10 lines, numbered 1...10 in their own text, so assertions can check exact content.
    private let tenLineFile = (1...10).map { "line \($0)" }.joined(separator: "\n")

    func testLoadWithRangeHighlightsExactlyTheCitedLinesAndIncludesContext() throws {
        let repoRoot = try makeRepoWithFile("a.py", contents: tenLineFile)

        let snippet = try EvidenceSourceLoader.load(
            repoRoot: repoRoot, anchor: "a.py::foo", startLine: 5, endLine: 6, contextLines: 2)

        XCTAssertEqual(snippet.filePath, "a.py")
        XCTAssertEqual(snippet.highlightRange, 5...6)
        XCTAssertEqual(snippet.lines.map(\.number), [3, 4, 5, 6, 7, 8])
        XCTAssertEqual(snippet.lines.first(where: { $0.number == 5 })?.text, "line 5")
    }

    func testLoadClampsContextAtFileBoundaries() throws {
        let repoRoot = try makeRepoWithFile("a.py", contents: tenLineFile)

        let snippet = try EvidenceSourceLoader.load(
            repoRoot: repoRoot, anchor: "a.py::foo", startLine: 1, endLine: 2, contextLines: 5)

        XCTAssertEqual(snippet.lines.first?.number, 1)  // never goes below line 1

        let snippetAtEnd = try EvidenceSourceLoader.load(
            repoRoot: repoRoot, anchor: "a.py::bar", startLine: 9, endLine: 10, contextLines: 5)
        XCTAssertEqual(snippetAtEnd.lines.last?.number, 10)  // never exceeds the real line count
    }

    func testLoadWithNoRangeReturnsCappedWholeFileAndNoHighlight() throws {
        let repoRoot = try makeRepoWithFile("a.py", contents: tenLineFile)

        let snippet = try EvidenceSourceLoader.load(
            repoRoot: repoRoot, anchor: "a.py", startLine: nil, endLine: nil,
            maxLinesWithNoRange: 100)

        XCTAssertNil(snippet.highlightRange)
        XCTAssertEqual(snippet.lines.count, 10)
    }

    func testLoadCapsLineCountWhenNoRangeIsGiven() throws {
        let longFile = (1...500).map { "line \($0)" }.joined(separator: "\n")
        let repoRoot = try makeRepoWithFile("big.py", contents: longFile)

        let snippet = try EvidenceSourceLoader.load(
            repoRoot: repoRoot, anchor: "big.py", startLine: nil, endLine: nil,
            maxLinesWithNoRange: 50)

        XCTAssertEqual(snippet.lines.count, 50)
    }

    func testLoadThrowsWhenFileDoesNotExist() {
        let repoRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("EvidenceSourceLoaderTests-missing-\(UUID().uuidString)")

        XCTAssertThrowsError(
            try EvidenceSourceLoader.load(
                repoRoot: repoRoot, anchor: "missing.py::foo", startLine: 1, endLine: 2)
        ) { error in
            guard case EvidenceSourceError.fileNotFound = error else {
                return XCTFail("expected fileNotFound, got \(error)")
            }
        }
    }

    func testLoadThrowsWhenStartLineIsBeyondEndOfFile() throws {
        let repoRoot = try makeRepoWithFile("a.py", contents: tenLineFile)

        XCTAssertThrowsError(
            try EvidenceSourceLoader.load(
                repoRoot: repoRoot, anchor: "a.py::foo", startLine: 999, endLine: 1000)
        ) { error in
            guard case EvidenceSourceError.invalidRange = error else {
                return XCTFail("expected invalidRange, got \(error)")
            }
        }
    }

    func testFilePathIsExtractedFromAnchorBeforeTheDoubleColon() throws {
        let repoRoot = try makeRepoWithFile("pkg/module.py", contents: tenLineFile)

        let snippet = try EvidenceSourceLoader.load(
            repoRoot: repoRoot, anchor: "pkg/module.py::Class.method", startLine: 1, endLine: 1)

        XCTAssertEqual(snippet.filePath, "pkg/module.py")
    }
}
