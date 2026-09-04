import XCTest
import SwiftTreeSitter
@testable import OrionCodeIntel

final class TreeSitterParserTests: XCTestCase {

    private func parse(_ source: String) throws -> ParsedTree {
        let parser = try TreeSitterParser(PythonLanguageSupport())
        return try XCTUnwrap(
            parser.parse(fileId: "f", relPath: "m.py", source: Data(source.utf8))
        )
    }

    func testParsesCleanSourceWithNoErrors() throws {
        let tree = try parse("def f(x):\n    return x + 1\n")
        XCTAssertEqual(tree.rootNode?.nodeType, "module")
        XCTAssertFalse(tree.rootNode?.hasError ?? true)
        XCTAssertTrue(PythonParsePass().errorSpans(in: tree).isEmpty)
    }

    func testByteRangesAreUTF8AndMapToLines() throws {
        let src = "x = 1\nclass Widget:\n    pass\n"
        let tree = try parse(src)
        var classNode: Node?
        tree.walk { node in
            if node.nodeType == "class_definition" { classNode = node; return false }
            return true
        }
        let node = try XCTUnwrap(classNode)
        // "class" keyword starts at line 2, column 1 (byte offset 6).
        XCTAssertEqual(Int(node.byteRange.lowerBound), 6)
        let pos = tree.lineIndex.position(ofByte: Int(node.byteRange.lowerBound))
        XCTAssertEqual(pos, .init(line: 2, column: 1))
        XCTAssertTrue(tree.text(of: node).hasPrefix("class Widget"))
    }

    func testUTF8OffsetsSurviveNonASCII() throws {
        // A leading 2-byte char must not shift byte offsets into UTF-16 space.
        let tree = try parse("π = 3\nY = 4\n")
        var second: Node?
        tree.walk { node in
            if node.nodeType == "identifier", tree.text(of: node) == "Y" { second = node; return false }
            return true
        }
        let node = try XCTUnwrap(second)
        // "π"(2) + " = 3\n"(5) = 7
        XCTAssertEqual(Int(node.byteRange.lowerBound), 7)
        XCTAssertEqual(
            tree.lineIndex.position(ofByte: Int(node.byteRange.lowerBound)),
            .init(line: 2, column: 1)
        )
    }
}

final class PythonParsePassTests: XCTestCase {

    private func outcome(_ files: [String: String], jobs: Int = 1) throws -> [FileParseOutcome] {
        let tmp = try TempDir()
        var specs: [ParseFileSpec] = []
        for (rel, body) in files {
            try tmp.write(rel, body)
            specs.append(ParseFileSpec(fileId: rel, relPath: rel, absolutePath: tmp.path(rel)))
        }
        return PythonParsePass().run(specs, jobs: jobs)
    }

    func testCleanFileParsesOk() throws {
        let out = try outcome(["a.py": "def f():\n    return 1\n"])
        XCTAssertEqual(out.count, 1)
        XCTAssertTrue(out[0].parseOk)
        XCTAssertTrue(out[0].errors.isEmpty)
    }

    func testSyntaxErrorProducesSpan() throws {
        let out = try outcome(["bad.py": "def f(:\n    pass\n"])
        XCTAssertFalse(out[0].parseOk)
        XCTAssertTrue(out[0].parsed)
        XCTAssertGreaterThanOrEqual(out[0].errors.count, 1)
        XCTAssertEqual(out[0].errors.first?.startLine, 1)
    }

    func testMissingNodeIsReported() throws {
        // Unterminated bracket -> tree-sitter inserts a MISSING node.
        let out = try outcome(["m.py": "x = [1, 2\n"])
        XCTAssertFalse(out[0].parseOk)
        XCTAssertTrue(out[0].errors.contains { $0.kind == .missing || $0.kind == .error })
    }

    func testMissingFileYieldsNotParsed() throws {
        let specs = [ParseFileSpec(fileId: "x", relPath: "x.py", absolutePath: "/no/such/file.py")]
        let out = PythonParsePass().run(specs, jobs: 1)
        XCTAssertEqual(out.count, 1)
        XCTAssertFalse(out[0].parsed)
        XCTAssertFalse(out[0].parseOk)
    }

    func testParallelMatchesSequential() throws {
        let files = Dictionary(
            uniqueKeysWithValues: (0..<20).map { ("m\($0).py", "x\($0) = \($0)\n") }
        )
        let seq = try outcome(files, jobs: 1).sorted { $0.fileId < $1.fileId }
        let par = try outcome(files, jobs: 8).sorted { $0.fileId < $1.fileId }
        XCTAssertEqual(seq.map(\.fileId), par.map(\.fileId))
        XCTAssertEqual(seq.map(\.parseOk), par.map(\.parseOk))
    }
}

final class ASTCacheTests: XCTestCase {

    func testEntryParsesAndCaches() throws {
        let cache = ASTCache(language: PythonLanguageSupport())
        let src = Data("a = 1\n".utf8)
        let first = try XCTUnwrap(cache.entry(fileId: "f", relPath: "f.py", source: src))
        XCTAssertEqual(first.rootNode?.nodeType, "module")
        XCTAssertEqual(cache.count, 1)
        _ = try cache.entry(fileId: "f", relPath: "f.py", source: src)
        XCTAssertEqual(cache.count, 1)
    }

    func testEvictsBeyondCapacity() throws {
        let cache = ASTCache(capacity: 2, parserFactory: { try TreeSitterParser(PythonLanguageSupport()) })
        for i in 0..<5 {
            _ = try cache.entry(fileId: "f\(i)", relPath: "f\(i).py", source: Data("x=\(i)\n".utf8))
        }
        XCTAssertEqual(cache.count, 2)
    }
}
