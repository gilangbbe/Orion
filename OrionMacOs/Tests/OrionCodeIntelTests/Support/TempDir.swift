import Foundation

/// A throwaway directory removed on `deinit`.
final class TempDir {
    let url: URL

    init(_ name: String = "orion-test") throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: url) }

    /// Write `contents` to `relPath`, creating parent directories.
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
