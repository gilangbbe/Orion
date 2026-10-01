import Foundation

/// The repositories on this device (Docs/19 M3): one folder per `libraryKey`, holding the imported
/// knowledge database (`orion.db`, the snapshot plus this device's own learning and asking) and
/// the manifest of the snapshot it came from.
///
/// ```
/// <root>/<libraryKey>/orion.db
/// <root>/<libraryKey>/manifest.json
/// ```
public struct LocalLibrary: Sendable {
    public let root: URL

    public struct Entry: Equatable, Sendable {
        public let manifest: KnowledgeSnapshotManifest
        public let databaseURL: URL
        public var libraryKey: String { manifest.libraryKey }
    }

    public init(root: URL) {
        self.root = root
    }

    /// `Application Support/Orion/Library`.
    public static func defaultRoot() throws -> URL {
        try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("Orion/Library", isDirectory: true)
    }

    public func folder(for libraryKey: String) -> URL {
        root.appendingPathComponent(libraryKey, isDirectory: true)
    }

    public func databaseURL(for libraryKey: String) -> URL {
        folder(for: libraryKey).appendingPathComponent("orion.db")
    }

    public func manifestURL(for libraryKey: String) -> URL {
        folder(for: libraryKey).appendingPathComponent("manifest.json")
    }

    /// Every imported repository, by name. A folder without a readable manifest and database (an
    /// interrupted first import) is skipped.
    public func entries() throws -> [Entry] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        let folders = try FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        return folders.compactMap { folder -> Entry? in
            let key = folder.lastPathComponent
            guard FileManager.default.fileExists(atPath: databaseURL(for: key).path),
                  let data = try? Data(contentsOf: manifestURL(for: key)),
                  let manifest = try? KnowledgeSnapshotManifest.decode(data)
            else { return nil }
            return Entry(manifest: manifest, databaseURL: databaseURL(for: key))
        }
        .sorted { ($0.manifest.repositoryName.lowercased(), $0.libraryKey) < ($1.manifest.repositoryName.lowercased(), $1.libraryKey) }
    }

    public func entry(for libraryKey: String) throws -> Entry? {
        try entries().first { $0.libraryKey == libraryKey }
    }

    /// Deletes a repository and everything learned on this device about it.
    public func remove(libraryKey: String) throws {
        let folder = folder(for: libraryKey)
        if FileManager.default.fileExists(atPath: folder.path) {
            try FileManager.default.removeItem(at: folder)
        }
    }
}
