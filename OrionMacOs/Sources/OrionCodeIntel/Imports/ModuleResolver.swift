import Foundation

/// Path-based resolution of an import module spec to an in-repo module, or to an external
/// top-level package. No type checker — just `RepoLayout`'s dotted module paths
/// (resolved open question #3: unusual layouts fall through to `.unresolvable`).
public struct ModuleResolver {
    public let inRepoModules: Set<String>
    private let inRepoTopLevels: Set<String>

    public init(inRepoModules: Set<String>) {
        self.inRepoModules = inRepoModules
        self.inRepoTopLevels = Set(inRepoModules.compactMap { $0.split(separator: ".").first.map(String.init) })
    }

    public enum Target: Equatable {
        case inRepoModule(String)
        case external(topLevel: String, full: String)
        case unresolvable(String)
    }

    /// `spec`: absolute `a.b.c`, or relative `.`, `.mod`, `..pkg.mod`.
    /// `importedName`: the `y` in `from spec import y`, so `spec.y` can be tried as a submodule.
    public func resolve(
        spec: String, importedName: String?,
        importerModulePath: String, importerIsPackage: Bool
    ) -> Target {
        if spec.hasPrefix(".") {
            return resolveRelative(
                spec: spec, importedName: importedName,
                importerModulePath: importerModulePath, importerIsPackage: importerIsPackage
            )
        }
        return resolveAbsolute(spec: spec, importedName: importedName)
    }

    // MARK: absolute

    private func resolveAbsolute(spec: String, importedName: String?) -> Target {
        // `from spec import name` may name a submodule (`spec.name`) or a symbol in `spec`.
        if let name = importedName, inRepoModules.contains("\(spec).\(name)") {
            return .inRepoModule("\(spec).\(name)")
        }
        if inRepoModules.contains(spec) {
            return .inRepoModule(spec)
        }
        let top = spec.split(separator: ".").first.map(String.init) ?? spec
        if inRepoTopLevels.contains(top) { return .unresolvable(spec) }
        return .external(topLevel: top, full: spec)
    }

    // MARK: relative

    private func resolveRelative(
        spec: String, importedName: String?,
        importerModulePath: String, importerIsPackage: Bool
    ) -> Target {
        var level = 0
        for ch in spec { if ch == "." { level += 1 } else { break } }
        let remainder = String(spec.dropFirst(level))

        var base = importerIsPackage ? importerModulePath : parentDotted(importerModulePath)
        for _ in 1..<max(level, 1) {   // each dot past the first climbs one package
            if base.isEmpty { return .unresolvable(spec) }
            base = parentDotted(base)
        }

        let absolute: String
        if remainder.isEmpty {
            absolute = base
        } else {
            absolute = base.isEmpty ? remainder : "\(base).\(remainder)"
        }

        if let name = importedName, inRepoModules.contains("\(absolute).\(name)") {
            return .inRepoModule("\(absolute).\(name)")
        }
        if inRepoModules.contains(absolute) {
            return .inRepoModule(absolute)
        }
        return .unresolvable(spec)
    }

    private func parentDotted(_ s: String) -> String {
        guard let dot = s.lastIndex(of: ".") else { return "" }
        return String(s[s.startIndex..<dot])
    }
}
