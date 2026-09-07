import Foundation

struct SourceLine: Identifiable, Equatable {
    var id: Int { number }
    let number: Int
    let text: String
}

struct EvidenceSnippet: Equatable {
    let filePath: String
    let lines: [SourceLine]
    /// `nil` when no line range is known (a bare module anchor) -- the whole capped snippet is
    /// shown with nothing highlighted, rather than guessing a range.
    let highlightRange: ClosedRange<Int>?
}

enum EvidenceSourceError: Error, CustomStringConvertible {
    case fileNotFound(String)
    case invalidRange(String)

    var description: String {
        switch self {
        case .fileNotFound(let path): return "couldn't read \(path) from the analyzed checkout"
        case .invalidRange(let anchor): return "invalid line range for \(anchor)"
        }
    }
}

/// Docs/13_phase4_architecture_ui.md M5's "evidence view": reads the real file from the analyzed
/// checkout and slices it to the cited range, with a little surrounding context -- plain
/// monospace + line numbers, real syntax highlighting is a stretch goal, not required for v1
/// (Docs/08 asks for an "evidence view," not a code editor). Pure logic, no SwiftUI.
enum EvidenceSourceLoader {
    static func load(
        repoRoot: URL, anchor: String, startLine: Int?, endLine: Int?, contextLines: Int = 3,
        maxLinesWithNoRange: Int = 200
    ) throws -> EvidenceSnippet {
        let filePath = String(anchor.split(separator: "::", maxSplits: 1).first ?? Substring(anchor))
        let fileURL = repoRoot.appendingPathComponent(filePath)
        guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else {
            throw EvidenceSourceError.fileNotFound(filePath)
        }
        let allLines = content.components(separatedBy: "\n")

        guard let start = startLine, let end = endLine, start >= 1, end >= start else {
            let capped = allLines.prefix(maxLinesWithNoRange)
            let numbered = capped.enumerated().map { SourceLine(number: $0.offset + 1, text: $0.element) }
            return EvidenceSnippet(filePath: filePath, lines: numbered, highlightRange: nil)
        }
        guard start <= allLines.count else {
            throw EvidenceSourceError.invalidRange(anchor)
        }

        let lowerBound = max(1, start - contextLines)
        let upperBound = min(allLines.count, end + contextLines)
        let slice = allLines[(lowerBound - 1)..<upperBound]
        let numbered = slice.enumerated().map {
            SourceLine(number: lowerBound + $0.offset, text: $0.element)
        }
        return EvidenceSnippet(filePath: filePath, lines: numbered, highlightRange: start...end)
    }
}
