import CloudKit
import XCTest

@testable import OrionCore
@testable import OrionSync

/// Docs/19 M5: the parts of iCloud sync that don't need iCloud -- the snapshot ⇄ record mapping,
/// chunking, the outbox, and persisted sync state. `CKRecord`, `CKAsset` and system-field coding
/// all work offline; only `CKSyncEngine` itself needs a signed-in container, so it's exercised
/// live (Docs/19 M5 results), not here.
final class OrionSyncTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("orion-sync-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func manifest(key: String = "abc123") -> KnowledgeSnapshotManifest {
        KnowledgeSnapshotManifest(
            schemaVersion: "v7_ios_snapshot", libraryKey: key, repositoryName: "demo", sourceURL: nil,
            commitHash: "c0ffee", runId: "run", analyzedAt: "t0", createdAt: "t1", orionVersion: "0.1.0",
            counts: .init(
                files: 1, symbols: 2, relationships: 3, components: 4, claims: 5, evidence: 6, modelRevisions: 7,
                teachingConcepts: 8, teachingQuestions: 9, snippets: 10, snippetsSkipped: 0),
            databaseByteCount: 2048, snapshotByteCount: 1000, sha256: "deadbeef")
    }

    private func snapshotFile(bytes: Int) throws -> URL {
        let url = dir.appendingPathComponent("demo.orionsnap")
        try Data((0..<bytes).map { UInt8($0 % 251) }).write(to: url)
        return url
    }

    // MARK: - Record mapping

    func testRecordRoundTripsTheManifestAndFile() throws {
        let file = try snapshotFile(bytes: 10_000)
        let parts = try SnapshotCloud.chunk(file, into: dir.appendingPathComponent("parts"))
        XCTAssertEqual(parts.count, 1)

        let record = CKRecord(recordType: SnapshotCloud.recordType, recordID: SnapshotCloud.recordID(libraryKey: "abc123"))
        try SnapshotCloud.populate(record, manifest: manifest(), parts: parts)
        XCTAssertEqual(record.recordID.zoneID, SnapshotCloud.zoneID)
        XCTAssertEqual(record[SnapshotCloud.Field.formatVersion] as? Int, KnowledgeSnapshotFormat.formatVersion)

        let (decoded, assembled) = try SnapshotCloud.assemble(record, into: dir.appendingPathComponent("in"))
        XCTAssertEqual(decoded, manifest())
        XCTAssertEqual(try Data(contentsOf: assembled), try Data(contentsOf: file))
        XCTAssertEqual(assembled.lastPathComponent, "abc123.orionsnap")
    }

    /// The manifest names the repository, so it travels encrypted, never as a plain field.
    func testManifestIsAnEncryptedField() throws {
        let file = try snapshotFile(bytes: 10)
        let record = CKRecord(recordType: SnapshotCloud.recordType, recordID: SnapshotCloud.recordID(libraryKey: "abc123"))
        try SnapshotCloud.populate(record, manifest: manifest(), parts: [file])
        XCTAssertNil(record[SnapshotCloud.Field.manifest])
        XCTAssertNotNil(record.encryptedValues[SnapshotCloud.Field.manifest])
    }

    func testLargeSnapshotsAreChunkedAndReassembledInOrder() throws {
        let file = try snapshotFile(bytes: 2_500)
        let parts = try SnapshotCloud.chunk(file, into: dir.appendingPathComponent("parts"), maxBytes: 1_000)
        XCTAssertEqual(parts.map(\.lastPathComponent), ["part-000", "part-001", "part-002"])
        let record = CKRecord(recordType: SnapshotCloud.recordType, recordID: SnapshotCloud.recordID(libraryKey: "abc123"))
        try SnapshotCloud.populate(record, manifest: manifest(), parts: parts)
        let (_, assembled) = try SnapshotCloud.assemble(record, into: dir.appendingPathComponent("in"))
        XCTAssertEqual(try Data(contentsOf: assembled), try Data(contentsOf: file))
    }

    func testOtherRecordsAreRejected() {
        let record = CKRecord(recordType: "Something", recordID: CKRecord.ID(recordName: "x", zoneID: SnapshotCloud.zoneID))
        XCTAssertThrowsError(try SnapshotCloud.assemble(record, into: dir)) { error in
            XCTAssertEqual(error as? SnapshotCloud.CloudError, .notASnapshotRecord("x"))
        }
        let empty = CKRecord(recordType: SnapshotCloud.recordType, recordID: SnapshotCloud.recordID(libraryKey: "k"))
        empty.encryptedValues[SnapshotCloud.Field.manifest] = String(decoding: try! manifest(key: "k").json(), as: UTF8.self)
        XCTAssertThrowsError(try SnapshotCloud.assemble(empty, into: dir)) { error in
            XCTAssertEqual(error as? SnapshotCloud.CloudError, .missingPayload("k"))
        }
    }

    // MARK: - Outbox

    func testOutboxStagesReplacesAndRemoves() throws {
        let outbox = SnapshotOutbox(directory: dir.appendingPathComponent("Outbox"))
        try outbox.stage(snapshot: try snapshotFile(bytes: 2_500), manifest: manifest(), maxChunkBytes: 1_000)
        XCTAssertEqual(try outbox.entry(libraryKey: "abc123").parts.count, 3)
        XCTAssertEqual(outbox.libraryKeys(), ["abc123"])

        // A newer snapshot for the same repository replaces the staged one.
        var newer = manifest()
        newer.commitHash = "f00d"
        try outbox.stage(snapshot: try snapshotFile(bytes: 500), manifest: newer, maxChunkBytes: 1_000)
        let entry = try outbox.entry(libraryKey: "abc123")
        XCTAssertEqual(entry.manifest.commitHash, "f00d")
        XCTAssertEqual(entry.parts.count, 1)

        outbox.remove(libraryKey: "abc123")
        XCTAssertEqual(outbox.libraryKeys(), [])
        XCTAssertThrowsError(try outbox.entry(libraryKey: "abc123"))
    }

    // MARK: - Persisted state

    func testSystemFieldsSurviveARelaunch() throws {
        let store = SyncStateStore(directory: dir.appendingPathComponent("State"))
        let id = SnapshotCloud.recordID(libraryKey: "abc123")
        XCTAssertNil(store.lastSavedRecord(id))

        store.saveSystemFields(of: CKRecord(recordType: SnapshotCloud.recordType, recordID: id))
        let relaunched = SyncStateStore(directory: dir.appendingPathComponent("State"))
        let restored = try XCTUnwrap(relaunched.lastSavedRecord(id))
        XCTAssertEqual(restored.recordID, id)
        XCTAssertEqual(restored.recordType, SnapshotCloud.recordType)

        relaunched.removeSystemFields(id)
        XCTAssertNil(relaunched.lastSavedRecord(id))
    }

    func testResetForgetsEverything() {
        let store = SyncStateStore(directory: dir.appendingPathComponent("State"))
        let id = SnapshotCloud.recordID(libraryKey: "abc123")
        store.saveSystemFields(of: CKRecord(recordType: SnapshotCloud.recordType, recordID: id))
        store.reset()
        XCTAssertNil(store.lastSavedRecord(id))
        XCTAssertNil(store.engineState())
    }
}
