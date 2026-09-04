import Foundation
import SwiftTreeSitter

/// Lifts structural symbols from a parsed Python file: the module itself, classes,
/// functions/methods/properties, module- and class-level variables/constants, import
/// aliases, and — in `__init__.py` — synthetic `reexport` symbols.
///
/// A tree walk (not `.scm` queries) because the output is hierarchical: qualified names,
/// parent links, and benchmark-form anchors all need the nesting structure. The bundled
/// `python-symbols.scm` still pins the node types we depend on (checked by `GrammarTests`).
public struct PythonSymbolExtractor {
    public init() {}

    private enum Scope { case module, classBody, functionBody }

    private static let controlFlow: Set<String> = [
        "if_statement", "elif_clause", "else_clause", "try_statement", "except_clause",
        "except_group_clause", "finally_clause", "with_statement", "for_statement",
        "while_statement", "match_statement", "case_clause",
    ]

    public func extract(
        _ parsed: ParsedTree, modulePath: String?, isPackageInit: Bool
    ) -> FileSymbols {
        var symbols: [ExtractedSymbol] = []
        var diagnostics: [ExtractionDiagnostic] = []

        guard let root = parsed.rootNode else {
            return FileSymbols(
                fileId: parsed.fileId, relPath: parsed.relPath, modulePath: modulePath,
                symbols: [], diagnostics: []
            )
        }

        let moduleAnchor = parsed.relPath
        let moduleQN = modulePath ?? parsed.relPath
        let moduleName = modulePath?.split(separator: ".").last.map(String.init)
            ?? (parsed.relPath as NSString).lastPathComponent

        symbols.append(makeSymbol(
            kind: isPackageInit ? .package : .module, name: moduleName,
            qualifiedName: moduleQN, anchor: moduleAnchor, parentAnchor: nil,
            node: root, parsed: parsed, signature: nil,
            docstring: docstring(inBody: root, parsed: parsed), decorators: [], redirectsTo: nil
        ))

        let all = parseDunderAll(root, parsed: parsed, diagnostics: &diagnostics)

        var ctx = WalkContext(
            parentAnchor: moduleAnchor, dottedPrefix: "", scope: .module,
            moduleQN: moduleQN, relPath: parsed.relPath, isPackageInit: isPackageInit
        )
        walk(container: root, parsed: parsed, ctx: &ctx, into: &symbols, diagnostics: &diagnostics)

        // Export rules: top-level names follow __all__ when present, else visibility.
        for i in symbols.indices where symbols[i].parentAnchor == moduleAnchor {
            switch symbols[i].kind {
            case .module, .package:
                symbols[i].isExported = true
            default:
                symbols[i].isExported = all.names.map { $0.contains(symbols[i].name) }
                    ?? (symbols[i].visibility == "public")
            }
        }

        // Last binding of an anchor wins (Python shadowing), keep byte order.
        var seen: [String: Int] = [:]
        var deduped: [ExtractedSymbol] = []
        for sym in symbols {
            if let idx = seen[sym.anchor] {
                deduped[idx] = sym
            } else {
                seen[sym.anchor] = deduped.count
                deduped.append(sym)
            }
        }
        deduped.sort { $0.startByte < $1.startByte }

        return FileSymbols(
            fileId: parsed.fileId, relPath: parsed.relPath, modulePath: modulePath,
            symbols: deduped, diagnostics: diagnostics
        )
    }

    // MARK: walk

    private struct WalkContext {
        var parentAnchor: String
        var dottedPrefix: String
        var scope: Scope
        var moduleQN: String
        var relPath: String
        var isPackageInit: Bool
    }

    private func walk(
        container: Node, parsed: ParsedTree, ctx: inout WalkContext,
        into symbols: inout [ExtractedSymbol], diagnostics: inout [ExtractionDiagnostic]
    ) {
        for i in 0..<container.namedChildCount {
            guard let stmt = container.namedChild(at: i) else { continue }
            switch stmt.nodeType {
            case "decorated_definition":
                let decorators = decoratorNames(of: stmt, parsed: parsed)
                if let def = stmt.child(byFieldName: "definition") {
                    handleDefinition(
                        def, span: stmt, decorators: decorators, parsed: parsed,
                        ctx: &ctx, into: &symbols, diagnostics: &diagnostics
                    )
                }
            case "function_definition", "class_definition":
                handleDefinition(
                    stmt, span: stmt, decorators: [], parsed: parsed,
                    ctx: &ctx, into: &symbols, diagnostics: &diagnostics
                )
            case "expression_statement" where ctx.scope != .functionBody:
                if let assign = stmt.namedChild(at: 0), assign.nodeType == "assignment" {
                    handleAssignment(assign, parsed: parsed, ctx: ctx, into: &symbols)
                }
            case "import_statement", "import_from_statement", "future_import_statement":
                if ctx.scope != .functionBody {
                    handleImport(stmt, parsed: parsed, ctx: ctx, into: &symbols, diagnostics: &diagnostics)
                }
            case let t? where Self.controlFlow.contains(t):
                for block in childBlocks(of: stmt) {
                    walk(container: block, parsed: parsed, ctx: &ctx, into: &symbols, diagnostics: &diagnostics)
                }
            default:
                break
            }
        }
    }

    private func childBlocks(of node: Node) -> [Node] {
        var blocks: [Node] = []
        for i in 0..<node.namedChildCount {
            guard let child = node.namedChild(at: i) else { continue }
            if child.nodeType == "block" {
                blocks.append(child)
            } else if let t = child.nodeType, Self.controlFlow.contains(t) {
                blocks.append(contentsOf: childBlocks(of: child))
            }
        }
        return blocks
    }

    private func handleDefinition(
        _ def: Node, span: Node, decorators: [String], parsed: ParsedTree,
        ctx: inout WalkContext, into symbols: inout [ExtractedSymbol],
        diagnostics: inout [ExtractionDiagnostic]
    ) {
        guard let nameNode = def.child(byFieldName: "name") else { return }
        let name = parsed.text(of: nameNode)
        let dotted = ctx.dottedPrefix.isEmpty ? name : "\(ctx.dottedPrefix).\(name)"
        let anchor = "\(ctx.relPath)::\(dotted)"
        let qn = "\(ctx.moduleQN).\(dotted)"

        let kind: SymbolKind
        var signature: String?
        if def.nodeType == "class_definition" {
            kind = .class
        } else if ctx.scope == .classBody {
            kind = isProperty(decorators) ? .property : .method
            signature = functionSignature(def, parsed: parsed)
        } else {
            kind = .function
            signature = functionSignature(def, parsed: parsed)
        }

        symbols.append(makeSymbol(
            kind: kind, name: name, qualifiedName: qn, anchor: anchor,
            parentAnchor: ctx.parentAnchor, node: span, parsed: parsed,
            signature: signature, docstring: def.child(byFieldName: "body").map {
                docstring(inBody: $0, parsed: parsed)
            } ?? nil,
            decorators: decorators, redirectsTo: nil
        ))

        guard let body = def.child(byFieldName: "body") else { return }
        var childCtx = WalkContext(
            parentAnchor: anchor, dottedPrefix: dotted,
            scope: def.nodeType == "class_definition" ? .classBody : .functionBody,
            moduleQN: ctx.moduleQN, relPath: ctx.relPath, isPackageInit: ctx.isPackageInit
        )
        walk(container: body, parsed: parsed, ctx: &childCtx, into: &symbols, diagnostics: &diagnostics)
    }

    private func handleAssignment(
        _ assign: Node, parsed: ParsedTree, ctx: WalkContext,
        into symbols: inout [ExtractedSymbol]
    ) {
        guard let left = assign.child(byFieldName: "left") else { return }
        for name in bindingNames(in: left, parsed: parsed) {
            let dotted = ctx.dottedPrefix.isEmpty ? name : "\(ctx.dottedPrefix).\(name)"
            let kind: SymbolKind = isConstantName(name) ? .constant : .variable
            symbols.append(makeSymbol(
                kind: kind, name: name, qualifiedName: "\(ctx.moduleQN).\(dotted)",
                anchor: "\(ctx.relPath)::\(dotted)", parentAnchor: ctx.parentAnchor,
                node: assign, parsed: parsed, signature: nil, docstring: nil,
                decorators: [], redirectsTo: nil
            ))
        }
    }

    private func handleImport(
        _ stmt: Node, parsed: ParsedTree, ctx: WalkContext,
        into symbols: inout [ExtractedSymbol], diagnostics: inout [ExtractionDiagnostic]
    ) {
        // `from __future__ import …` is a compiler directive, not a binding.
        if stmt.nodeType == "future_import_statement" { return }

        let isFrom = (stmt.nodeType == "import_from_statement")
        var moduleSpec = ""
        if isFrom, let m = stmt.child(byFieldName: "module_name") {
            moduleSpec = parsed.text(of: m)
        }

        // wildcard: `from x import *`
        for i in 0..<stmt.namedChildCount where stmt.namedChild(at: i)?.nodeType == "wildcard_import" {
            let pos = parsed.lineIndex.position(ofByte: Int(stmt.byteRange.lowerBound))
            diagnostics.append(ExtractionDiagnostic(
                code: "WILDCARD_IMPORT",
                message: "`from \(moduleSpec) import *` — bound names are not statically known",
                line: pos.line, col: pos.column
            ))
        }

        // A re-export is a *relative* `from .x import y` in a package __init__ — the
        // intentional "lift a submodule name to the package" pattern (resolved Q#4).
        // Absolute `from typing import Any` in an __init__ stays a plain import alias.
        let isReexport = isFrom && ctx.isPackageInit && moduleSpec.hasPrefix(".")

        for (local, original) in importBindings(in: stmt, isFrom: isFrom, parsed: parsed) {
            let dotted = ctx.dottedPrefix.isEmpty ? local : "\(ctx.dottedPrefix).\(local)"
            let kind: SymbolKind = isReexport ? .reexport : .importAlias
            let redirect = isFrom ? "\(moduleSpec)::\(original)" : original
            symbols.append(makeSymbol(
                kind: kind, name: local, qualifiedName: "\(ctx.moduleQN).\(dotted)",
                anchor: "\(ctx.relPath)::\(dotted)", parentAnchor: ctx.parentAnchor,
                node: stmt, parsed: parsed, signature: nil, docstring: nil,
                decorators: [], redirectsTo: redirect
            ))
        }
    }

    // MARK: node helpers

    /// `(local bound name, original dotted target)` for each imported name — the `name`
    /// field children only, never the `module_name` field.
    private func importBindings(
        in stmt: Node, isFrom: Bool, parsed: ParsedTree
    ) -> [(local: String, original: String)] {
        var result: [(String, String)] = []
        for i in 0..<stmt.childCount {
            guard stmt.fieldNameForChild(at: i) == "name", let child = stmt.child(at: i)
            else { continue }
            switch child.nodeType {
            case "dotted_name":
                let full = parsed.text(of: child)
                if isFrom {
                    result.append((full, full))
                } else {
                    // `import a.b.c` binds `a`
                    result.append((full.split(separator: ".").first.map(String.init) ?? full, full))
                }
            case "aliased_import":
                let original = child.child(byFieldName: "name").map { parsed.text(of: $0) } ?? ""
                let alias = child.child(byFieldName: "alias").map { parsed.text(of: $0) } ?? original
                result.append((alias, original))
            default:
                break
            }
        }
        return result
    }

    private func bindingNames(in left: Node, parsed: ParsedTree) -> [String] {
        switch left.nodeType {
        case "identifier":
            return [parsed.text(of: left)]
        case "pattern_list", "tuple_pattern", "list_pattern":
            var names: [String] = []
            for i in 0..<left.namedChildCount {
                if let c = left.namedChild(at: i) { names.append(contentsOf: bindingNames(in: c, parsed: parsed)) }
            }
            return names
        default:
            return []   // attribute / subscript / starred — not a simple binding
        }
    }

    private func decoratorNames(of decorated: Node, parsed: ParsedTree) -> [String] {
        var names: [String] = []
        for i in 0..<decorated.namedChildCount {
            guard let child = decorated.namedChild(at: i), child.nodeType == "decorator" else { continue }
            var text = parsed.text(of: child).trimmingCharacters(in: .whitespacesAndNewlines)
            if text.hasPrefix("@") { text.removeFirst() }
            names.append(text.trimmingCharacters(in: .whitespaces))
        }
        return names
    }

    private func isProperty(_ decorators: [String]) -> Bool {
        decorators.contains { d in
            d == "property" || d.hasSuffix(".setter") || d.hasSuffix(".getter")
                || d.hasSuffix(".deleter") || d == "cached_property"
                || d.hasSuffix(".cached_property")
        }
    }

    private func functionSignature(_ def: Node, parsed: ParsedTree) -> String {
        let params = def.child(byFieldName: "parameters").map { parsed.text(of: $0) } ?? "()"
        let ret = def.child(byFieldName: "return_type").map { " -> \(parsed.text(of: $0))" } ?? ""
        return collapseWhitespace(params + ret)
    }

    private func docstring(inBody body: Node, parsed: ParsedTree) -> String? {
        guard let first = body.namedChild(at: 0), first.nodeType == "expression_statement",
              let str = first.namedChild(at: 0), str.nodeType == "string"
        else { return nil }
        var content = ""
        for i in 0..<str.namedChildCount where str.namedChild(at: i)?.nodeType == "string_content" {
            content += parsed.text(of: str.namedChild(at: i)!)
        }
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : String(trimmed.prefix(2000))
    }

    private func isConstantName(_ name: String) -> Bool {
        guard name.uppercased() == name else { return false }
        return name.rangeOfCharacter(from: CharacterSet.letters) != nil
    }

    private func collapseWhitespace(_ s: String) -> String {
        s.split(whereSeparator: { $0 == "\n" || $0 == "\t" || $0 == " " })
            .joined(separator: " ")
    }

    private func makeSymbol(
        kind: SymbolKind, name: String, qualifiedName: String, anchor: String,
        parentAnchor: String?, node: Node, parsed: ParsedTree, signature: String?,
        docstring: String?, decorators: [String], redirectsTo: String?
    ) -> ExtractedSymbol {
        let r = node.byteRange
        let start = parsed.lineIndex.position(ofByte: Int(r.lowerBound))
        let end = parsed.lineIndex.position(ofByte: Int(r.upperBound))
        return ExtractedSymbol(
            kind: kind, name: name, qualifiedName: qualifiedName, anchor: anchor,
            parentAnchor: parentAnchor, startByte: Int(r.lowerBound), endByte: Int(r.upperBound),
            startLine: start.line, startCol: start.column, endLine: end.line, endCol: end.column,
            signature: signature, docstring: docstring, decorators: decorators,
            visibility: SymbolVisibility.classify(name),
            isExported: SymbolVisibility.classify(name) == "public", redirectsTo: redirectsTo
        )
    }

    // MARK: __all__

    struct DunderAll { var names: Set<String>? }

    private func parseDunderAll(
        _ root: Node, parsed: ParsedTree, diagnostics: inout [ExtractionDiagnostic]
    ) -> DunderAll {
        var found = false
        var collected: Set<String> = []

        func scan(_ container: Node) {
            for i in 0..<container.namedChildCount {
                guard let stmt = container.namedChild(at: i) else { continue }
                if let t = stmt.nodeType, Self.controlFlow.contains(t) {
                    for b in childBlocks(of: stmt) { scan(b) }
                    continue
                }
                guard stmt.nodeType == "expression_statement",
                      let assign = stmt.namedChild(at: 0),
                      assign.nodeType == "assignment" || assign.nodeType == "augmented_assignment",
                      let left = assign.child(byFieldName: "left"),
                      left.nodeType == "identifier", parsed.text(of: left) == "__all__",
                      let right = assign.child(byFieldName: "right")
                else { continue }

                found = true
                if let statics = staticStrings(right, parsed: parsed) {
                    collected.formUnion(statics)
                } else {
                    let pos = parsed.lineIndex.position(ofByte: Int(right.byteRange.lowerBound))
                    diagnostics.append(ExtractionDiagnostic(
                        code: "DYNAMIC_ALL",
                        message: "__all__ is not a static list/tuple of string literals",
                        line: pos.line, col: pos.column
                    ))
                    collected = []
                    found = false   // treat as absent
                    return
                }
            }
        }
        scan(root)
        return DunderAll(names: found ? collected : nil)
    }

    private func staticStrings(_ node: Node, parsed: ParsedTree) -> [String]? {
        switch node.nodeType {
        case "string":
            var content = ""
            for i in 0..<node.namedChildCount where node.namedChild(at: i)?.nodeType == "string_content" {
                content += parsed.text(of: node.namedChild(at: i)!)
            }
            return [content]
        case "concatenated_string":
            var parts: [String] = []
            for i in 0..<node.namedChildCount {
                guard let c = node.namedChild(at: i), let s = staticStrings(c, parsed: parsed)
                else { return nil }
                parts.append(contentsOf: s)
            }
            return [parts.joined()]
        case "list", "tuple", "set", "parenthesized_expression":
            var out: [String] = []
            for i in 0..<node.namedChildCount {
                guard let c = node.namedChild(at: i), let s = staticStrings(c, parsed: parsed)
                else { return nil }
                out.append(contentsOf: s)
            }
            return out
        case "binary_operator":
            guard let l = node.child(byFieldName: "left"), let r = node.child(byFieldName: "right"),
                  let ls = staticStrings(l, parsed: parsed), let rs = staticStrings(r, parsed: parsed)
            else { return nil }
            return ls + rs
        default:
            return nil
        }
    }
}
