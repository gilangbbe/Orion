import CloudKit
import Foundation
import OrionCore

/// How a knowledge snapshot lives in CloudKit (Docs/19 M5).
///
/// - **Private database**, so only the user's own devices see it. Custom zone
///   `OrionKnowledge` (the default zone has no change tracking, which `CKSyncEngine` needs).
/// - **One `KnowledgeSnapshot` record per repository**, named by its `libraryKey`, so a newer
///   snapshot replaces the older one instead of piling up.
/// - **The file goes as `CKAsset`s** (`payload`), which CloudKit encrypts by default. A snapshot
///   above `maxChunkBytes` is split into ordered parts, keeping each asset under CloudKit's 50 MB
///   limit (Docs/19 M0 finding 7). Starlette's is 0.8 MB, so in practice there's one part.
/// - **The manifest goes in `encryptedValues`**: it names the repository, and nothing ever
///   queries or sorts on it. Only `formatVersion` is plain, so a newer format is recognizable
///   without decrypting anything.
public enum SnapshotCloud {
    public static let containerIdentifier = "iCloud.com.gilangbbe.orion"
    public static let zoneID = CKRecordZone.ID(zoneName: "OrionKnowledge", ownerName: CKCurrentUserDefaultName)
    public static let recordType = "KnowledgeSnapshot"
    /// Comfortably under CloudKit's 50 MB per-asset limit.
    public static let maxChunkBytes = 45 * 1024 * 1024

    public enum Field {
        /// `KnowledgeSnapshotManifest` JSON (encrypted).
        public static let manifest = "manifest"
        /// `[CKAsset]`, the `.orionsnap` file's bytes in order.
        public static let payload = "payload"
        /// `KnowledgeSnapshotFormat.formatVersion` (plain).
        public static let formatVersion = "formatVersion"
    }

    public enum CloudError: Error, LocalizedError, Equatable {
        case notASnapshotRecord(String)
        case missingPayload(String)

        public var errorDescription: String? {
            switch self {
            case .notASnapshotRecord(let name): return "iCloud record \(name) isn't an Orion knowledge snapshot."
            case .missingPayload(let name): return "iCloud record \(name) has no snapshot file attached."
            }
        }
    }

    public static func recordID(libraryKey: String) -> CKRecord.ID {
        CKRecord.ID(recordName: libraryKey, zoneID: zoneID)
    }

    // MARK: - Writing (the Mac)

    /// Splits `snapshot` into parts of at most `maxBytes` inside `directory`, in order.
    public static func chunk(_ snapshot: URL, into directory: URL, maxBytes: Int = maxChunkBytes) throws -> [URL] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try Data(contentsOf: snapshot)
        var parts: [URL] = []
        var offset = 0
        repeat {
            let end = min(offset + maxBytes, data.count)
            let part = directory.appendingPathComponent(String(format: "part-%03d", parts.count))
            try data.subdata(in: offset..<end).write(to: part, options: .atomic)
            parts.append(part)
            offset = end
        } while offset < data.count
        return parts
    }

    /// Sets a snapshot record's fields. `record` should carry the last-saved system fields when
    /// there are any, so the save has the right change tag.
    public static func populate(_ record: CKRecord, manifest: KnowledgeSnapshotManifest, parts: [URL]) throws {
        record.encryptedValues[Field.manifest] = String(decoding: try manifest.json(), as: UTF8.self)
        record[Field.formatVersion] = manifest.formatVersion as CKRecordValue
        record[Field.payload] = parts.map { CKAsset(fileURL: $0) } as CKRecordValue
    }

    // MARK: - Reading (the iPhone)

    /// The manifest a record carries.
    public static func manifest(of record: CKRecord) throws -> KnowledgeSnapshotManifest {
        guard record.recordType == recordType, let json = record.encryptedValues[Field.manifest] as? String else {
            throw CloudError.notASnapshotRecord(record.recordID.recordName)
        }
        return try KnowledgeSnapshotManifest.decode(Data(json.utf8))
    }

    /// Joins a fetched record's asset parts into `<directory>/<libraryKey>.orionsnap`. The asset
    /// files CloudKit hands over are temporary, so this runs inside the fetch event, before
    /// anything else.
    public static func assemble(_ record: CKRecord, into directory: URL) throws -> (manifest: KnowledgeSnapshotManifest, file: URL) {
        let manifest = try manifest(of: record)
        guard let assets = record[Field.payload] as? [CKAsset], !assets.isEmpty else {
            throw CloudError.missingPayload(record.recordID.recordName)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var bytes = Data()
        for asset in assets {
            guard let url = asset.fileURL else { throw CloudError.missingPayload(record.recordID.recordName) }
            bytes.append(try Data(contentsOf: url))
        }
        let file = directory.appendingPathComponent("\(manifest.libraryKey).\(KnowledgeSnapshotFormat.fileExtension)")
        try bytes.write(to: file, options: .atomic)
        return (manifest, file)
    }
}
