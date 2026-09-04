import XCTest
@testable import OrionCodeIntel

final class LineIndexTests: XCTestCase {

    func testBasicMapping() {
        let idx = LineIndex(text: "abc\ndef\n\nghi")
        XCTAssertEqual(idx.position(ofByte: 0), .init(line: 1, column: 1))
        XCTAssertEqual(idx.position(ofByte: 2), .init(line: 1, column: 3))
        XCTAssertEqual(idx.position(ofByte: 3), .init(line: 1, column: 4))  // the '\n'
        XCTAssertEqual(idx.position(ofByte: 4), .init(line: 2, column: 1))  // 'd'
        XCTAssertEqual(idx.position(ofByte: 8), .init(line: 3, column: 1))  // empty line
        XCTAssertEqual(idx.position(ofByte: 9), .init(line: 4, column: 1))  // 'g'
    }

    func testClampsOutOfRange() {
        let idx = LineIndex(text: "ab")
        XCTAssertEqual(idx.position(ofByte: -5), .init(line: 1, column: 1))
        XCTAssertEqual(idx.position(ofByte: 99), .init(line: 1, column: 3))
    }

    func testLineCount() {
        XCTAssertEqual(LineIndex(text: "").lineCount, 0)
        XCTAssertEqual(LineIndex(text: "a").lineCount, 1)
        XCTAssertEqual(LineIndex(text: "a\nb").lineCount, 2)
        XCTAssertEqual(LineIndex(text: "a\nb\n").lineCount, 2)
    }

    func testColumnsAreByteOffsets() {
        // "é" is 2 UTF-8 bytes; the char after it sits at byte column 3.
        let idx = LineIndex(text: "é=1")
        XCTAssertEqual(idx.position(ofByte: 2), .init(line: 1, column: 3))  // the '='
    }
}
