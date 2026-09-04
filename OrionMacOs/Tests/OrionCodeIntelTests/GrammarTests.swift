import XCTest
import SwiftTreeSitter
@testable import OrionCodeIntel

/// Guards the pinned `tree-sitter-python` grammar: verifies it loads with an ABI compatible
/// with the pinned `SwiftTreeSitter` runtime, and that the node types our `.scm` queries and
/// extractors depend on still exist. A grammar bump that renames nodes fails here loudly
/// (resolved open question #1).
final class GrammarTests: XCTestCase {

    /// Node types referenced by `python-symbols.scm` / the Phase 1 extractors.
    private static let requiredNodeTypes: Set<String> = [
        "module",
        "function_definition",
        "class_definition",
        "decorated_definition",
        "decorator",
        "import_statement",
        "import_from_statement",
        "aliased_import",
        "dotted_name",
        "identifier",
        "expression_statement",
        "assignment",
        "call",
        "attribute",
        "argument_list",
    ]

    private static let sample = """
    import os
    from typing import Optional as Opt
    from . import sibling

    CONST = 3

    @decorator
    def top_level(a, b=1) -> int:
        return a + b

    class Widget(Base):
        \"\"\"A widget.\"\"\"

        def method(self, x):
            self.value = x
            return os.path.join("a", "b")
    """

    private func makeParser() throws -> Parser {
        let parser = Parser()
        try parser.setLanguage(PythonLanguageSupport.cachedLanguage)
        return parser
    }

    func testGrammarLoadsAndParses() throws {
        let parser = try makeParser()
        let tree = try XCTUnwrap(parser.parse(Self.sample), "parser produced no tree")
        let root = try XCTUnwrap(tree.rootNode, "tree has no root node")
        XCTAssertEqual(root.nodeType, "module")
        XCTAssertFalse(root.hasError, "well-formed sample should parse without ERROR nodes")
    }

    func testRequiredNodeTypesArePresent() throws {
        let parser = try makeParser()
        let tree = try XCTUnwrap(parser.parse(Self.sample))
        let root = try XCTUnwrap(tree.rootNode)

        var seen: Set<String> = []
        var stack: [Node] = [root]
        while let node = stack.popLast() {
            if let type = node.nodeType { seen.insert(type) }
            for i in 0..<node.childCount {
                if let child = node.child(at: i) { stack.append(child) }
            }
        }

        let missing = Self.requiredNodeTypes.subtracting(seen).sorted()
        XCTAssertTrue(
            missing.isEmpty,
            "tree-sitter-python is missing expected node types: \(missing.joined(separator: ", "))"
        )
    }

    func testBundledSymbolQueryLoadsAndCompiles() throws {
        let source = try BundledQueries.source(named: "python-symbols")
        XCTAssertFalse(source.isEmpty)
        // Compiling against the grammar catches capture/predicate errors in the .scm.
        XCTAssertNoThrow(
            try Query(language: PythonLanguageSupport.cachedLanguage, data: Data(source.utf8))
        )
    }
}
