import CloudKit
import Foundation
import OrionCore

/// Snapshots waiting to be (re)uploaded, kept on disk so a publish survives a quit, a lost network
/// or an account switch (Docs/19 M5). One folder per repository:
///
/// ```
/// <directory>/<libraryKey>/manifest.json
/// <directory>/<libraryKey>/parts/part-000 …   (the .orionsnap, chunked for CKAsset)
/// ```
///
/// The skill's rule for sync code: make the local change durable first, then enqueue it.
public struct SnapshotOutbox: Sendable {
    public let directory: URL

    public struct Entry: Sendable {
        public let manifest: KnowledgeSnapshotManifest
        public let parts: [URL]
    }

    public init(directory: URL) {
        self.directory = directory
    }

    private func folder(_ libraryKey: String) -> URL {
        directory.appendingPathComponent(libraryKey, isDirectory: true)
    }

    /// Replaces any staged snapshot for the same repository.
    public func stage(snapshot: URL, manifest: KnowledgeSnapshotManifest, maxChunkBytes: Int = SnapshotCloud.maxChunkBytes) throws {
        let folder = folder(manifest.libraryKey)
        let staging = directory.appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        _ = try SnapshotCloud.chunk(snapshot, into: staging.appendingPathComponent("parts"), maxBytes: maxChunkBytes)
        try manifest.json().write(to: staging.appendingPathComponent("manifest.json"), options: .atomic)
        if FileManager.default.fileExists(atPath: folder.path) {
            _ = try FileManager.default.replaceItemAt(folder, withItemAt: staging)
        } else {
            try FileManager.default.moveItem(at: staging, to: folder)
        }
    }

    public func entry(libraryKey: String) throws -> Entry {
        let folder = folder(libraryKey)
        let manifest = try KnowledgeSnapshotManifest.decode(Data(contentsOf: folder.appendingPathComponent("manifest.json")))
        let parts = try FileManager.default
            .contentsOfDirectory(at: folder.appendingPathComponent("parts"), includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("part-") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        return Entry(manifest: manifest, parts: parts)
    }

    public func libraryKeys() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
            .filter { !$0.hasPrefix(".") }
            .sorted()
    }

    public func remove(libraryKey: String) {
        try? FileManager.default.removeItem(at: folder(libraryKey))
    }
}

/// The Mac side of iCloud sync (Docs/19 M5): uploads staged snapshots to the private database
/// with `CKSyncEngine`, which schedules the work, retries transient failures and persists its
/// change tokens (through `SyncStateStore`).
///
/// The Mac is the only writer of a snapshot record, so a `serverRecordChanged` conflict is
/// resolved by keeping the Mac's content on top of the server record's change tag -- the skill's
/// "merge into `serverRecord`", where every field is the Mac's -- and saving again.
public final class SnapshotPublisher: CKSyncEngineDelegate, @unchecked Sendable {
    public enum Status: Equatable, Sendable {
        case pending
        case uploaded(Date)
        case failed(String)
    }

    public let outbox: SnapshotOutbox
    private let state: SyncStateStore
    private let onStatus: @Sendable (_ libraryKey: String, Status) -> Void
    private var engine: CKSyncEngine!

    /// - Parameters:
    ///   - directory: where the outbox and sync state live (the Mac app uses
    ///     `Application Support/Orion/Sync`).
    ///   - onStatus: per-repository upload status, called from the engine's queue.
    public init(
        directory: URL, database: CKDatabase,
        onStatus: @escaping @Sendable (_ libraryKey: String, Status) -> Void
    ) {
        self.outbox = SnapshotOutbox(directory: directory.appendingPathComponent("Outbox", isDirectory: true))
        self.state = SyncStateStore(directory: directory.appendingPathComponent("PublisherState", isDirectory: true))
        self.onStatus = onStatus
        self.engine = CKSyncEngine(CKSyncEngine.Configuration(
            database: database, stateSerialization: state.engineState(), delegate: self))
    }

    /// Stages `snapshot` and schedules its upload, replacing what's in iCloud for that repository.
    public func publish(snapshot: URL, manifest: KnowledgeSnapshotManifest) throws {
        try outbox.stage(snapshot: snapshot, manifest: manifest)
        enqueue(libraryKey: manifest.libraryKey)
    }

    /// Stops syncing a repository and deletes its snapshot from iCloud. The iPhone keeps its copy.
    public func unpublish(libraryKey: String) {
        outbox.remove(libraryKey: libraryKey)
        engine.state.add(pendingRecordZoneChanges: [.deleteRecord(SnapshotCloud.recordID(libraryKey: libraryKey))])
    }

    /// Upload now rather than whenever the engine next schedules it.
    public func sendNow() async throws {
        try await engine.sendChanges()
    }

    private func enqueue(libraryKey: String) {
        // Saving an existing zone is a no-op on the server, so asking every time is safe and covers
        // a zone the user deleted from iCloud settings.
        engine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: SnapshotCloud.zoneID))])
        engine.state.add(pendingRecordZoneChanges: [.saveRecord(SnapshotCloud.recordID(libraryKey: libraryKey))])
        onStatus(libraryKey, .pending)
    }

    // MARK: - CKSyncEngineDelegate

    public func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        switch event {
        case .stateUpdate(let update):
            state.saveEngineState(update.stateSerialization)
        case .accountChange(let change):
            switch change.changeType {
            case .signIn:
                outbox.libraryKeys().forEach(enqueue(libraryKey:))
            case .signOut:
                state.reset()
            case .switchAccounts:
                state.reset()
                outbox.libraryKeys().forEach(enqueue(libraryKey:))
            @unknown default:
                break
            }
        case .sentRecordZoneChanges(let sent):
            for record in sent.savedRecords {
                state.saveSystemFields(of: record)
                onStatus(record.recordID.recordName, .uploaded(Date()))
            }
            for failure in sent.failedRecordSaves {
                handleSaveFailure(failure, syncEngine: syncEngine)
            }
            // A deleted record's change tag is meaningless now; a later publish starts fresh.
            for recordID in sent.deletedRecordIDs {
                state.removeSystemFields(recordID)
            }
        default:
            break
        }
    }

    private func handleSaveFailure(_ failure: CKSyncEngine.Event.SentRecordZoneChanges.FailedRecordSave, syncEngine: CKSyncEngine) {
        let recordID = failure.record.recordID
        let key = recordID.recordName
        switch failure.error.code {
        case .serverRecordChanged:
            // Keep the server's change tag, put the Mac's content back on top, save again.
            if let server = failure.error.serverRecord { state.saveSystemFields(of: server) }
            syncEngine.state.add(pendingRecordZoneChanges: [.saveRecord(recordID)])
        case .zoneNotFound, .userDeletedZone:
            syncEngine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: SnapshotCloud.zoneID))])
            syncEngine.state.add(pendingRecordZoneChanges: [.saveRecord(recordID)])
        case .unknownItem:
            // Deleted on the server since the last save: start over from a fresh record.
            state.removeSystemFields(recordID)
            syncEngine.state.add(pendingRecordZoneChanges: [.saveRecord(recordID)])
        case .quotaExceeded:
            onStatus(key, .failed("Your iCloud storage is full."))
        case .networkFailure, .networkUnavailable, .zoneBusy, .serviceUnavailable, .requestRateLimited:
            // Transient: the engine retries these itself; keep the change pending.
            syncEngine.state.add(pendingRecordZoneChanges: [.saveRecord(recordID)])
            onStatus(key, .pending)
        case .notAuthenticated:
            onStatus(key, .failed("Sign in to iCloud on this Mac to sync."))
        default:
            onStatus(key, .failed(failure.error.localizedDescription))
        }
    }

    public func nextRecordZoneChangeBatch(
        _ context: CKSyncEngine.SendChangesContext, syncEngine: CKSyncEngine
    ) async -> CKSyncEngine.RecordZoneChangeBatch? {
        let changes = syncEngine.state.pendingRecordZoneChanges.filter { context.options.scope.contains($0) }
        guard !changes.isEmpty else { return nil }
        let outbox = outbox
        let state = state
        return await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: changes) { recordID in
            guard let entry = try? outbox.entry(libraryKey: recordID.recordName) else {
                // Unpublished since it was enqueued.
                syncEngine.state.remove(pendingRecordZoneChanges: [.saveRecord(recordID)])
                return nil
            }
            let record = state.lastSavedRecord(recordID)
                ?? CKRecord(recordType: SnapshotCloud.recordType, recordID: recordID)
            do {
                try SnapshotCloud.populate(record, manifest: entry.manifest, parts: entry.parts)
            } catch {
                syncEngine.state.remove(pendingRecordZoneChanges: [.saveRecord(recordID)])
                return nil
            }
            return record
        }
    }
}
