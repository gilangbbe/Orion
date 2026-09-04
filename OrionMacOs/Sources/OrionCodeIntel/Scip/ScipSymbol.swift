import Foundation

/// Parses a SCIP symbol string into the pieces Orion needs to join it back to a
/// tree-sitter symbol anchor.
///
/// Format (SCIP spec): `<scheme> <manager> <package> <version> <descriptors>`, or the
/// special forms `local <id>` and `. . . . <descriptors>`. `scip-python` descriptors look
/// like `` `pkg.mod`/Class#method(). `` — a backtick-quoted namespace (the dotted module
/// path), then `/`-separated `Type#` / `term.` / `method().` / `__init__:` / `(param)`.
public struct ScipSymbol: Equatable {
    public enum DescriptorKind: Equatable {
        case namespace, type, term, method, meta, macro, parameter, typeParameter
    }

    public let scheme: String
    public let manager: String
    public let package: String
    public let version: String
    public let descriptors: [(name: String, kind: DescriptorKind)]
    public let isLocal: Bool

    public static func == (a: ScipSymbol, b: ScipSymbol) -> Bool {
        a.scheme == b.scheme && a.manager == b.manager && a.package == b.package
            && a.version == b.version && a.isLocal == b.isLocal
            && a.descriptors.map(\.name) == b.descriptors.map(\.name)
            && a.descriptors.map(\.kind) == b.descriptors.map(\.kind)
    }

    public init?(_ raw: String) {
        if raw.hasPrefix("local ") {
            scheme = "local"; manager = ""; package = ""; version = ""
            descriptors = []; isLocal = true
            return
        }
        // First 4 space-separated fields are metadata; the rest is the descriptor string
        // (scip-python never puts spaces in descriptors outside backticks, which its module
        // names don't use).
        let parts = raw.split(separator: " ", maxSplits: 4, omittingEmptySubsequences: false)
        guard parts.count == 5 else { return nil }
        scheme = String(parts[0]); manager = String(parts[1])
        package = String(parts[2]); version = String(parts[3])
        isLocal = false
        descriptors = ScipSymbol.parseDescriptors(String(parts[4]))
    }

    // MARK: derived

    /// Dotted module path (the leading namespace descriptor), e.g. `starlette.responses`.
    public var moduleDotted: String? {
        guard let first = descriptors.first, first.kind == .namespace else {
            // some top packages come as a single namespace/meta pair without backticks
            return descriptors.first(where: { $0.kind == .namespace })?.name
        }
        return first.name
    }

    /// In-file dotted nesting (types/terms/methods after the module), e.g.
    /// `Starlette.build_middleware_stack`. Empty for a module symbol.
    public var inFileDotted: String {
        descriptors
            .dropFirst(descriptors.first?.kind == .namespace ? 1 : 0)
            .filter { $0.kind == .type || $0.kind == .term || $0.kind == .method }
            .map(\.name)
            .joined(separator: ".")
    }

    /// True when this names a module/package rather than a symbol inside one.
    public var isModuleSymbol: Bool {
        !descriptors.isEmpty && inFileDotted.isEmpty
    }

    public var leafKind: DescriptorKind? {
        descriptors.last(where: { $0.kind != .parameter && $0.kind != .typeParameter })?.kind
    }

    public var leafName: String? {
        descriptors.last(where: { $0.kind == .type || $0.kind == .term || $0.kind == .method })?.name
    }

    // MARK: descriptor scanner

    static func parseDescriptors(_ s: String) -> [(name: String, kind: DescriptorKind)] {
        var result: [(String, DescriptorKind)] = []
        let chars = Array(s)
        var i = 0

        func readName() -> String {
            if i < chars.count, chars[i] == "`" {
                i += 1
                var name = ""
                while i < chars.count, chars[i] != "`" { name.append(chars[i]); i += 1 }
                if i < chars.count { i += 1 } // closing backtick
                return name
            }
            var name = ""
            while i < chars.count, !"/#.:!([".contains(chars[i]) {
                name.append(chars[i]); i += 1
            }
            return name
        }

        while i < chars.count {
            let name = readName()
            guard i < chars.count else {
                if !name.isEmpty { result.append((name, .term)) }
                break
            }
            switch chars[i] {
            case "/":
                i += 1
                result.append((name, .namespace))
            case "#":
                i += 1
                result.append((name, .type))
            case ":":
                i += 1
                result.append((name, .meta))
            case "!":
                i += 1
                result.append((name, .macro))
            case "[":
                var inner = ""
                i += 1
                while i < chars.count, chars[i] != "]" { inner.append(chars[i]); i += 1 }
                if i < chars.count { i += 1 }
                result.append((inner.isEmpty ? name : inner, .typeParameter))
            case "(":
                // method `name().` or parameter `name(param)`
                var depth = 1
                i += 1
                var inner = ""
                while i < chars.count, depth > 0 {
                    if chars[i] == "(" { depth += 1 }
                    else if chars[i] == ")" { depth -= 1; if depth == 0 { break } }
                    inner.append(chars[i]); i += 1
                }
                if i < chars.count { i += 1 } // consume ')'
                if i < chars.count, chars[i] == "." {
                    i += 1
                    result.append((name, .method))
                } else {
                    result.append((inner.isEmpty ? name : inner, .parameter))
                }
            case ".":
                i += 1
                result.append((name, .term))
            default:
                i += 1
            }
        }
        return result
    }
}
