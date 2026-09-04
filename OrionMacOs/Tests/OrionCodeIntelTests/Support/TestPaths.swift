import Foundation
import XCTest

/// Locates repo assets for tests. The vendored Starlette checkout is gitignored, so
/// integration tests must `XCTSkip` when it is absent.
enum TestPaths {
    /// Walk up from this source file to the Orion repo root (the dir containing `Docs/`).
    static var orionRepoRoot: URL {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<12 {
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent("Docs").path),
               FileManager.default.fileExists(
                   atPath: dir.appendingPathComponent("OrionMacOs").path
               ) {
                return dir
            }
            dir.deleteLastPathComponent()
        }
        fatalError("could not locate Orion repo root from \(#filePath)")
    }

    static var vendoredStarlette: URL {
        orionRepoRoot
            .appendingPathComponent("Agent Feasibility Study")
            .appendingPathComponent("vendor")
            .appendingPathComponent("starlette")
    }

    static var vendoredStarletteExists: Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: vendoredStarlette.path, isDirectory: &isDir)
            && isDir.boolValue
    }

    static let starlettePinnedCommit = "4f250d6b814587e20c5365f0a5f0c4d42bcb929f"

    /// Skips the calling test when the vendored corpus is not checked out.
    static func requireStarlette() throws {
        try XCTSkipUnless(
            vendoredStarletteExists,
            "vendored Starlette not present at \(vendoredStarlette.path) (it is gitignored)"
        )
    }

    static var npxAvailable: Bool {
        for dir in ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]
            + (ProcessInfo.processInfo.environment["PATH"]?.split(separator: ":").map(String.init) ?? []) {
            if FileManager.default.isExecutableFile(atPath: "\(dir)/npx") { return true }
        }
        return false
    }

    static func requireNpx() throws {
        try XCTSkipUnless(npxAvailable, "npx not available; skipping scip-python resolution test")
    }
}
