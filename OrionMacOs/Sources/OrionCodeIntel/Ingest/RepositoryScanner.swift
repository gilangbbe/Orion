import Foundation
import CryptoKit

/// A discovered source file with its measured facts. The pipeline turns these into
/// `FileRecord`s once it has the repository/run ids.
public struct ScannedFile: Sendable {
    public let relPath: String
    public let language: SourceLanguage?
    public let sha256: String
    public let byteSize: Int
    public let lineCount: Int
    public let isTest: Bool
    public let modulePath: String?
    public let isPackageInit: Bool
    /// Non-nil when the file was recorded but not read/parsed (e.g. over the size cap).
    public let skippedReason: String?
}

public struct RepositoryScanner {
    public let root: URL
    public let maxFileBytes: Int

    private static let prunedDirectories: Set<String> = [
        ".git", ".hg", ".svn", ".venv", "venv", "env", "node_modules", "__pycache__",
        "build", "dist", ".tox", ".mypy_cache", ".pytest_cache", ".ruff_cache", ".orion",
        ".build", "DerivedData",
    ]

    public init(root: URL, maxFileBytes: Int = 2_000_000) {
        self.root = root
        self.maxFileBytes = maxFileBytes
    }

    /// `trackedRelPaths` from `git ls-files` when available; otherwise a filtered walk.
    public func scan(trackedRelPaths: [String]?) throws -> [ScannedFile] {
        let candidates = (trackedRelPaths ?? filesystemWalk()).sorted()
        let pythonRelPaths = candidates.filter {
            SourceLanguage(fileExtension: ($0 as NSString).pathExtension) == .python
        }
        let layout = RepoLayout(root: root, pythonRelPaths: pythonRelPaths)

        var result: [ScannedFile] = []
        result.reserveCapacity(candidates.count)
        for rel in candidates {
            let url = root.appendingPathComponent(rel)
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true
            else { continue }

            let size = values.fileSize ?? 0
            let language = SourceLanguage(fileExtension: (rel as NSString).pathExtension)
            let isTest = TestDetector.isTestPath(rel)
            let module = language == .python
                ? layout.moduleInfo(forRelPath: rel)
                : RepoLayout.ModuleInfo(modulePath: nil, isPackageInit: false)

            if size > maxFileBytes {
                result.append(ScannedFile(
                    relPath: rel, language: language, sha256: "", byteSize: size, lineCount: 0,
                    isTest: isTest, modulePath: module.modulePath,
                    isPackageInit: module.isPackageInit, skippedReason: "oversize"
                ))
                continue
            }

            guard let data = try? Data(contentsOf: url) else { continue }
            result.append(ScannedFile(
                relPath: rel, language: language,
                sha256: Self.hexDigest(data), byteSize: data.count,
                lineCount: Self.countLines(data), isTest: isTest,
                modulePath: module.modulePath, isPackageInit: module.isPackageInit,
                skippedReason: nil
            ))
        }
        return result
    }

    // MARK: helpers

    static func hexDigest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Number of lines: count of `\n`, plus one if the file is non-empty and lacks a
    /// trailing newline.
    static func countLines(_ data: Data) -> Int {
        if data.isEmpty { return 0 }
        var newlines = 0
        for byte in data where byte == 0x0A { newlines += 1 }
        return data.last == 0x0A ? newlines : newlines + 1
    }

    private func filesystemWalk() -> [String] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey]
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles], errorHandler: nil
        ) else { return [] }

        var paths: [String] = []
        let rootPath = root.standardizedFileURL.path
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: Set(keys))
            if values?.isDirectory == true {
                if Self.prunedDirectories.contains(url.lastPathComponent) {
                    enumerator.skipDescendants()
                }
                continue
            }
            guard values?.isRegularFile == true else { continue }
            let full = url.standardizedFileURL.path
            if full.hasPrefix(rootPath + "/") {
                paths.append(String(full.dropFirst(rootPath.count + 1)))
            }
        }
        return paths
    }
}
