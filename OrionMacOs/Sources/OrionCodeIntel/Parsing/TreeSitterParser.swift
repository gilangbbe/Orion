import Foundation
import SwiftTreeSitter
import TreeSitter

/// A tree-sitter parser bound to one grammar. Not thread-safe: create one per worker.
///
/// Parsing goes through the UTF-8 read-block API (not `Parser.parse(_ string:)`, which
/// SwiftTreeSitter runs as UTF-16), so `Node.byteRange` / `pointRange` are UTF-8 byte
/// offsets that line up with the file on disk and with `LineIndex`.
public final class TreeSitterParser {
    private let parser: Parser

    public init(_ support: any LanguageSupport) throws {
        parser = Parser()
        try parser.setLanguage(support.treeSitterLanguage())
    }

    public func parse(fileId: String, relPath: String, source: Data) -> ParsedTree? {
        let chunkSize = 1 << 16
        let readBlock: Parser.ReadBlock = { byteOffset, _ in
            guard byteOffset < source.count else { return Data() }
            let end = min(byteOffset + chunkSize, source.count)
            return source.subdata(in: byteOffset..<end)
        }
        guard let tree = parser.parse(
            tree: nil as Tree?, encoding: TSInputEncodingUTF8, readBlock: readBlock
        ) else { return nil }
        return ParsedTree(
            fileId: fileId, relPath: relPath, source: source,
            tree: tree, lineIndex: LineIndex(data: source)
        )
    }
}

/// A parsed file plus the machinery downstream stages need. Holds a non-`Sendable`
/// tree-sitter tree — consume it from a single task (the `ASTCache` is the owner).
public struct ParsedTree {
    public let fileId: String
    public let relPath: String
    public let source: Data
    public let tree: MutableTree
    public let lineIndex: LineIndex

    public var rootNode: Node? { tree.rootNode }

    /// UTF-8 text for a node's byte range.
    public func text(of node: Node) -> String {
        let r = node.byteRange
        let lo = Int(r.lowerBound), hi = min(Int(r.upperBound), source.count)
        guard lo <= hi else { return "" }
        return String(decoding: source.subdata(in: lo..<hi), as: UTF8.self)
    }

    /// Depth-first walk. Return `false` from `visit` to skip a node's children.
    public func walk(_ visit: (Node) -> Bool) {
        guard let root = rootNode else { return }
        var stack: [Node] = [root]
        while let node = stack.popLast() {
            guard visit(node) else { continue }
            for i in stride(from: node.childCount - 1, through: 0, by: -1) {
                if let child = node.child(at: i) { stack.append(child) }
            }
        }
    }
}
