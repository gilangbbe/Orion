import CloudKit
import Foundation
import OrionCore

/// The iPhone side of iCloud sync (Docs/19 M5): a `CKSyncEngine` that only fetches. Each
/// `KnowledgeSnapshot` record that arrives is assembled from its assets and handed to `install`
/// (the app runs `KnowledgeSnapshotImporter`, which carries the device's own learning across); a
/// deleted record is reported to `removed`, and the app keeps its copy but stops calling it synced.
///
/// The phone never writes, so there are no conflicts to resolve on this side.
public final class SnapshotReceiver: CKSyncEngineDelegate, @unchecked Sendable {
    public enum Status: Equatable, Sendable {
        case idle
        case fetching
        case upToDate(Date)
        case failed(String)
    }

    private let state: SyncStateStore
    private let incoming: URL
    private let install: @Sendable (URL, KnowledgeSnapshotManifest) async throws -> Void
    private let removed: @Sendable (_ libraryKey: String) async -> Void
    private let onStatus: @Sendable (Status) -> Void
    private var engine: CKSyncEngine!

    /// - Parameters:
    ///   - directory: where sync state and in-flight downloads live.
    ///   - install: imports an assembled snapshot; called once per changed record.
    ///   - removed: a repository the Mac stopped syncing.
    public init(
        directory: URL, database: CKDatabase,
        install: @escaping @Sendable (URL, KnowledgeSnapshotManifest) async throws -> Void,
        removed: @escaping @Sendable (_ libraryKey: String) async -> Void,
        onStatus: @escaping @Sendable (Status) -> Void
    ) {
        self.state = SyncStateStore(directory: directory.appendingPathComponent("ReceiverState", isDirectory: true))
        self.incoming = directory.appendingPathComponent("Incoming", isDirectory: true)
        self.install = install
        self.removed = removed
        self.onStatus = onStatus
        self.engine = CKSyncEngine(CKSyncEngine.Configuration(
            database: database, stateSerialization: state.engineState(), delegate: self))
    }

    /// Fetch now (pull-to-refresh, coming to the foreground) rather than waiting for a push.
    public func fetchNow() async throws {
        onStatus(.fetching)
        do {
            try await engine.fetchChanges()
            onStatus(.upToDate(Date()))
        } catch {
            onStatus(.failed(error.localizedDescription))
            throw error
        }
    }

    // MARK: - CKSyncEngineDelegate

    public func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        switch event {
        case .stateUpdate(let update):
            state.saveEngineState(update.stateSerialization)
        case .accountChange(let change):
            if case .signIn = change.changeType { return }
            // Signed out or switched: the old account's change tokens mean nothing now. The
            // library keeps what was already imported.
            state.reset()
        case .willFetchChanges:
            onStatus(.fetching)
        case .fetchedRecordZoneChanges(let changes):
            for modification in changes.modifications where modification.record.recordType == SnapshotCloud.recordType {
                await receive(modification.record)
            }
            for deletion in changes.deletions where deletion.recordType == SnapshotCloud.recordType {
                await removed(deletion.recordID.recordName)
            }
        case .didFetchChanges:
            onStatus(.upToDate(Date()))
        default:
            break
        }
    }

    /// Assembles and installs one record. The asset files are only valid during this event, so
    /// they're copied out first. A failure is reported and the record is left for the next fetch
    /// of a newer version; the library keeps what it had.
    func receive(_ record: CKRecord) async {
        let folder = incoming.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        do {
            let (manifest, file) = try SnapshotCloud.assemble(record, into: folder)
            try await install(file, manifest)
        } catch {
            onStatus(.failed(error.localizedDescription))
        }
    }

    public func nextRecordZoneChangeBatch(
        _ context: CKSyncEngine.SendChangesContext, syncEngine: CKSyncEngine
    ) async -> CKSyncEngine.RecordZoneChangeBatch? {
        nil
    }
}
