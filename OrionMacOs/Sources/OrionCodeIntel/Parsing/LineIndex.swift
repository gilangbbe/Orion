import Foundation

/// Maps UTF-8 byte offsets to 1-based `(line, column)` positions. This is the single source
/// of truth for locations (resolved open question #6): tree-sitter gives us UTF-8 byte
/// ranges, everything user-facing is derived here.
///
/// `column` is a 1-based **byte** column within the line (not a grapheme count) — adequate
/// for Phase 1 and consistent with the stored byte offsets.
public struct LineIndex: Sendable {
    /// Byte offset at which each line starts. `lineStarts[0] == 0`.
    public let lineStarts: [Int]
    public let byteCount: Int

    public init(data: Data) {
        var starts: [Int] = [0]
        for (i, byte) in data.enumerated() where byte == 0x0A {
            starts.append(i + 1)
        }
        self.lineStarts = starts
        self.byteCount = data.count
    }

    public init(text: String) {
        self.init(data: Data(text.utf8))
    }

    /// 1-based line count (a trailing newline does not add an empty line).
    public var lineCount: Int {
        if byteCount == 0 { return 0 }
        // lineStarts has one entry per '\n' plus the leading 0; a file ending in '\n'
        // produces a final start == byteCount which is not a real line.
        return lineStarts.last == byteCount ? lineStarts.count - 1 : lineStarts.count
    }

    public struct Position: Equatable, Sendable {
        public let line: Int
        public let column: Int
    }

    public func position(ofByte offset: Int) -> Position {
        let clamped = max(0, min(offset, byteCount))
        // largest index whose lineStart <= clamped
        var lo = 0, hi = lineStarts.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if lineStarts[mid] <= clamped { lo = mid } else { hi = mid - 1 }
        }
        return Position(line: lo + 1, column: clamped - lineStarts[lo] + 1)
    }
}
