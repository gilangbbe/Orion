import Foundation

/// Works out how repo-relative file paths map to dotted Python module paths.
///
/// Phase 1 handles the common cases: package at the repo root (Starlette) and a single
/// `src/` layout. `pyproject` `package-dir` remaps, editable installs, and multi-root
/// monorepos are out of scope — such files get `modulePath == nil` and a diagnostic
/// (resolved open question #3).
public struct RepoLayout {
    /// Repo-relative prefix that dotted module paths are computed against: "" or "src/".
    public let moduleRootPrefix: String

    public init(root: URL, pythonRelPaths: [String]) {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        let srcURL = root.appendingPathComponent("src", isDirectory: true)
        let hasSrcDir = fm.fileExists(atPath: srcURL.path, isDirectory: &isDir) && isDir.boolValue
        let anyUnderSrc = pythonRelPaths.contains { $0 == "src" || $0.hasPrefix("src/") }
        self.moduleRootPrefix = (hasSrcDir && anyUnderSrc) ? "src/" : ""
    }

    /// Test seam: construct with an explicit prefix.
    public init(moduleRootPrefix: String) {
        self.moduleRootPrefix = moduleRootPrefix
    }

    public struct ModuleInfo: Equatable {
        public let modulePath: String?
        public let isPackageInit: Bool
    }

    public func moduleInfo(forRelPath relPath: String) -> ModuleInfo {
        var path = relPath
        if !moduleRootPrefix.isEmpty {
            guard path.hasPrefix(moduleRootPrefix) else {
                return ModuleInfo(modulePath: nil, isPackageInit: false)
            }
            path.removeFirst(moduleRootPrefix.count)
        }

        var components = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard let last = components.last else {
            return ModuleInfo(modulePath: nil, isPackageInit: false)
        }

        let isInit = (last == "__init__.py" || last == "__init__.pyi")
        if isInit {
            components.removeLast()
        } else if let dot = last.lastIndex(of: ".") {
            components[components.count - 1] = String(last[last.startIndex..<dot])
        }

        components = components.filter { !$0.isEmpty }
        let dotted = components.isEmpty ? nil : components.joined(separator: ".")
        return ModuleInfo(modulePath: dotted, isPackageInit: isInit)
    }
}
