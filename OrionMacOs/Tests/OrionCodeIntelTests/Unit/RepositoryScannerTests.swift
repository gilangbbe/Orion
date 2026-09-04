import XCTest
@testable import OrionCodeIntel

final class RepositoryScannerTests: XCTestCase {

    func testCountLines() {
        XCTAssertEqual(RepositoryScanner.countLines(Data("".utf8)), 0)
        XCTAssertEqual(RepositoryScanner.countLines(Data("a".utf8)), 1)
        XCTAssertEqual(RepositoryScanner.countLines(Data("a\nb".utf8)), 2)
        XCTAssertEqual(RepositoryScanner.countLines(Data("a\nb\n".utf8)), 2)
        XCTAssertEqual(RepositoryScanner.countLines(Data("\n\n".utf8)), 2)
    }

    func testHexDigestIsSHA256() {
        // echo -n "" | shasum -a 256
        XCTAssertEqual(
            RepositoryScanner.hexDigest(Data()),
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        )
    }

    func testWalkFallbackFindsFilesAndPrunes() throws {
        let tmp = try TempDir()
        try tmp.write("pkg/__init__.py", "")
        try tmp.write("pkg/mod.py", "x = 1\n")
        try tmp.write("README.md", "# hi\n")
        try tmp.write(".venv/lib/junk.py", "should_be_pruned = True\n")
        try tmp.write("__pycache__/cached.py", "nope = 1\n")

        let scanner = RepositoryScanner(root: tmp.url)
        let scanned = try scanner.scan(trackedRelPaths: nil)
        let paths = Set(scanned.map(\.relPath))

        XCTAssertEqual(paths, ["pkg/__init__.py", "pkg/mod.py", "README.md"])
        let mod = scanned.first { $0.relPath == "pkg/mod.py" }
        XCTAssertEqual(mod?.language, .python)
        XCTAssertEqual(mod?.modulePath, "pkg.mod")
        XCTAssertEqual(mod?.lineCount, 1)
        XCTAssertEqual(scanned.first { $0.relPath == "README.md" }?.language, nil)
    }

    func testOversizeFileRecordedButNotRead() throws {
        let tmp = try TempDir()
        try tmp.write("big.py", String(repeating: "a = 1\n", count: 2000))
        let scanner = RepositoryScanner(root: tmp.url, maxFileBytes: 100)
        let scanned = try scanner.scan(trackedRelPaths: ["big.py"])
        XCTAssertEqual(scanned.count, 1)
        XCTAssertEqual(scanned[0].skippedReason, "oversize")
        XCTAssertEqual(scanned[0].sha256, "")
        XCTAssertGreaterThan(scanned[0].byteSize, 100)
    }

    func testHonorsTrackedListOverWalk() throws {
        let tmp = try TempDir()
        try tmp.write("tracked.py", "x = 1\n")
        try tmp.write("untracked.py", "y = 2\n")
        let scanned = try RepositoryScanner(root: tmp.url).scan(trackedRelPaths: ["tracked.py"])
        XCTAssertEqual(scanned.map(\.relPath), ["tracked.py"])
    }
}
