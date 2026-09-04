import Foundation
import SwiftTreeSitter

/// One syntax error located by tree-sitter (an `ERROR` node or a `MISSING` node).
public struct ParseErrorSpan: Sendable, Equatable {
    public enum Kind: String, Sendable { case error = "ERROR", missing = "MISSING" }
    public let kind: Kind
    public let startLine: Int
    public let startCol: Int
    public let endLine: Int
    public let endCol: Int
    public let snippet: String?
}

/// Result of parsing one file.
public struct FileParseOutcome: Sendable {
    public let fileId: String
    public let relPath: String
    /// A tree was produced at all.
    public let parsed: Bool
    public let errors: [ParseErrorSpan]

    public var parseOk: Bool { parsed && errors.isEmpty }
}

public struct ParseFileSpec: Sendable {
    public let fileId: String
    public let relPath: String
    public let absolutePath: String
    public init(fileId: String, relPath: String, absolutePath: String) {
        self.fileId = fileId
        self.relPath = relPath
        self.absolutePath = absolutePath
    }
}

/// Parses a batch of files and reports syntax errors. CPU-bound and independent per file, so
/// it fans out with `concurrentPerform` (honours `jobs == 1` for a deterministic sequential
/// run). A file with errors still yields whatever partial tree tree-sitter recovered — this
/// pass only reports; extraction stages work off the same partial trees.
public struct PythonParsePass {
    public let support: any LanguageSupport
    public let maxSpansPerFile: Int

    public init(support: any LanguageSupport = PythonLanguageSupport(), maxSpansPerFile: Int = 50) {
        self.support = support
        self.maxSpansPerFile = maxSpansPerFile
    }

    public func run(_ specs: [ParseFileSpec], jobs: Int) -> [FileParseOutcome] {
        guard !specs.isEmpty else { return [] }
        var outcomes = [FileParseOutcome?](repeating: nil, count: specs.count)

        if jobs <= 1 {
            for i in specs.indices { outcomes[i] = parseOne(specs[i]) }
        } else {
            let lock = NSLock()
            DispatchQueue.concurrentPerform(iterations: specs.count) { i in
                let outcome = parseOne(specs[i])
                lock.lock(); outcomes[i] = outcome; lock.unlock()
            }
        }
        return outcomes.compactMap { $0 }
    }

    private func parseOne(_ spec: ParseFileSpec) -> FileParseOutcome {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: spec.absolutePath)),
              let parser = try? TreeSitterParser(support),
              let parsed = parser.parse(fileId: spec.fileId, relPath: spec.relPath, source: data)
        else {
            return FileParseOutcome(
                fileId: spec.fileId, relPath: spec.relPath, parsed: false, errors: []
            )
        }
        return FileParseOutcome(
            fileId: spec.fileId, relPath: spec.relPath, parsed: true,
            errors: errorSpans(in: parsed)
        )
    }

    func errorSpans(in parsed: ParsedTree) -> [ParseErrorSpan] {
        guard let root = parsed.rootNode else { return [] }
        var spans: [ParseErrorSpan] = []
        var stack: [Node] = [root]

        while let node = stack.popLast(), spans.count < maxSpansPerFile {
            let isErrorNode = (node.nodeType == "ERROR")
            let isMissing = node.isMissing

            if isErrorNode || isMissing {
                let r = node.byteRange
                let start = parsed.lineIndex.position(ofByte: Int(r.lowerBound))
                let end = parsed.lineIndex.position(ofByte: Int(r.upperBound))
                var snippet = parsed.text(of: node)
                    .split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
                if snippet.count > 80 { snippet = String(snippet.prefix(80)) + "…" }
                spans.append(ParseErrorSpan(
                    kind: isMissing ? .missing : .error,
                    startLine: start.line, startCol: start.column,
                    endLine: end.line, endCol: end.column,
                    snippet: snippet.isEmpty ? nil : snippet
                ))
                continue   // don't descend into a reported error subtree
            }

            if node.hasError {
                for i in stride(from: node.childCount - 1, through: 0, by: -1) {
                    if let child = node.child(at: i) { stack.append(child) }
                }
            }
        }
        return spans
    }
}
