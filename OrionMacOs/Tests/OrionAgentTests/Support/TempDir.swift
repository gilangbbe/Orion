import Foundation

/// A throwaway directory removed on `deinit`. Duplicated from
/// `OrionCodeIntelTests/Support/TempDir.swift` -- test targets don't share support code across
/// targets in this package, and it's small enough that duplicating it beats adding a shared
/// test-utilities target for one 20-line helper.
final class TempDir {
    let url: URL

    init(_ name: String = "orion-agent-test") throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: url) }

    func write(_ relPath: String, _ contents: String) throws {
        let fileURL = url.appendingPathComponent(relPath)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try contents.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    func path(_ relPath: String) -> String {
        url.appendingPathComponent(relPath).path
    }
}
