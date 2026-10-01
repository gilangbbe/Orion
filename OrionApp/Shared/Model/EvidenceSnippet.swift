import Foundation
import OrionCore

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
    /// The lines stop before the range plus context does: a knowledge snapshot caps each snippet
    /// (Docs/19 M2). Never set for the Mac's own checkout reads.
    var truncated: Bool = false

    init(filePath: String, lines: [SourceLine], highlightRange: ClosedRange<Int>?, truncated: Bool = false) {
        self.filePath = filePath
        self.lines = lines
        self.highlightRange = highlightRange
        self.truncated = truncated
    }

    init(filePath: String, slice: EvidenceSlice.Slice) {
        self.init(
            filePath: filePath,
            lines: slice.lines.enumerated().map { SourceLine(number: slice.firstLine + $0.offset, text: $0.element) },
            highlightRange: slice.highlight, truncated: slice.truncated)
    }
}

/// Where an evidence view's lines come from (Docs/19 M3/M4): the Mac reads the analyzed checkout,
/// the iOS companion reads the snippets its knowledge snapshot carries. One `EvidenceView` renders
/// either.
protocol EvidenceSourceProviding: Sendable {
    func snippet(for evidence: EvidenceDetail) throws -> EvidenceSnippet
}

/// The Mac: the real file in the analyzed checkout.
struct CheckoutEvidenceSource: EvidenceSourceProviding {
    let repoRoot: URL

    func snippet(for evidence: EvidenceDetail) throws -> EvidenceSnippet {
        try EvidenceSourceLoader.load(
            repoRoot: repoRoot, anchor: evidence.anchor, startLine: evidence.startLine, endLine: evidence.endLine)
    }
}

/// The iOS companion: `evidence_snippets` in the imported snapshot at `<outputDirectory>/orion.db`.
struct SnapshotEvidenceSource: EvidenceSourceProviding {
    let outputDirectory: URL

    func snippet(for evidence: EvidenceDetail) throws -> EvidenceSnippet {
        let store = Store(try OrionDatabase(path: outputDirectory.appendingPathComponent("orion.db").path))
        guard let slice = try store.evidenceSlice(
            anchor: evidence.anchor, startLine: evidence.startLine, endLine: evidence.endLine)
        else { throw EvidenceSourceError.notInSnapshot(EvidenceSlice.filePath(forAnchor: evidence.anchor)) }
        return EvidenceSnippet(filePath: EvidenceSlice.filePath(forAnchor: evidence.anchor), slice: slice)
    }
}

enum EvidenceSourceError: Error, CustomStringConvertible {
    case fileNotFound(String)
    case invalidRange(String)
    /// The snapshot carries no lines for this reference: it only includes cited evidence, and
    /// skips a file that changed after the analysis (Docs/19 M2).
    case notInSnapshot(String)

    var description: String {
        switch self {
        case .fileNotFound(let path): return "couldn't read \(path) from the analyzed checkout"
        case .invalidRange(let anchor): return "invalid line range for \(anchor)"
        case .notInSnapshot(let path):
            return "The code for this reference in \(path) wasn't synced to this device. "
                + "Snapshots carry only the lines evidence cites; open it in Orion on your Mac."
        }
    }
}

/// Docs/13_phase4_architecture_ui.md M5's "evidence view": reads the real file from the analyzed
/// checkout and slices it to the cited range, with a little surrounding context -- plain
/// monospace + line numbers, real syntax highlighting is a stretch goal, not required for v1
/// (Docs/08 asks for an "evidence view," not a code editor). Pure logic, no SwiftUI.
///
/// The slicing itself is `OrionCore.EvidenceSlice` (Docs/19 M2), shared with the knowledge
/// snapshot's evidence snippets, so the phone shows exactly these lines (up to its cap).
enum EvidenceSourceLoader {
    static func load(
        repoRoot: URL, anchor: String, startLine: Int?, endLine: Int?,
        contextLines: Int = EvidenceSlice.defaultContextLines, maxLinesWithNoRange: Int = 200
    ) throws -> EvidenceSnippet {
        let filePath = EvidenceSlice.filePath(forAnchor: anchor)
        let fileURL = repoRoot.appendingPathComponent(filePath)
        guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else {
            throw EvidenceSourceError.fileNotFound(filePath)
        }
        let slice: EvidenceSlice.Slice
        do {
            slice = try EvidenceSlice.slice(
                lines: content.components(separatedBy: "\n"), start: startLine, end: endLine,
                context: contextLines, maxLinesWithNoRange: maxLinesWithNoRange)
        } catch {
            throw EvidenceSourceError.invalidRange(anchor)
        }
        return EvidenceSnippet(filePath: filePath, slice: slice)
    }
}
