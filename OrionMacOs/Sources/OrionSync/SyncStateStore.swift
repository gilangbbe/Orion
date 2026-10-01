import CloudKit
import Foundation

/// What a `CKSyncEngine` must remember across launches (Docs/19 M5), as files in one directory:
///
/// - `engine-state.json` -- the engine's `State.Serialization` (change tokens, pending changes).
///   Without it every launch would refetch everything from scratch.
/// - `system-fields/<recordName>` -- each record's last-saved system fields (`encodeSystemFields`).
///   A save built on them carries the server's change tag; one built on a fresh `CKRecord` would
///   be rejected as `serverRecordChanged` every time after the first.
public final class SyncStateStore: @unchecked Sendable {
    public let directory: URL
    private let lock = NSLock()

    public init(directory: URL) {
        self.directory = directory
    }

    private var engineStateURL: URL { directory.appendingPathComponent("engine-state.json") }
    private var systemFieldsDirectory: URL { directory.appendingPathComponent("system-fields", isDirectory: true) }

    private func systemFieldsURL(_ recordName: String) -> URL {
        systemFieldsDirectory.appendingPathComponent(recordName)
    }

    // MARK: - Engine state

    public func engineState() -> CKSyncEngine.State.Serialization? {
        lock.withLock {
            (try? Data(contentsOf: engineStateURL)).flatMap {
                try? JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: $0)
            }
        }
    }

    public func saveEngineState(_ state: CKSyncEngine.State.Serialization) {
        lock.withLock {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? JSONEncoder().encode(state).write(to: engineStateURL, options: .atomic)
        }
    }

    // MARK: - Record system fields

    /// A record carrying only the last-saved system fields for `recordID`, ready to be filled in
    /// and saved; `nil` when it was never saved from this device.
    public func lastSavedRecord(_ recordID: CKRecord.ID) -> CKRecord? {
        lock.withLock {
            guard let data = try? Data(contentsOf: systemFieldsURL(recordID.recordName)),
                  let coder = try? NSKeyedUnarchiver(forReadingFrom: data)
            else { return nil }
            coder.requiresSecureCoding = true
            defer { coder.finishDecoding() }
            return CKRecord(coder: coder)
        }
    }

    public func saveSystemFields(of record: CKRecord) {
        let coder = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: coder)
        coder.finishEncoding()
        lock.withLock {
            try? FileManager.default.createDirectory(at: systemFieldsDirectory, withIntermediateDirectories: true)
            try? coder.encodedData.write(to: systemFieldsURL(record.recordID.recordName), options: .atomic)
        }
    }

    public func removeSystemFields(_ recordID: CKRecord.ID) {
        lock.withLock { try? FileManager.default.removeItem(at: systemFieldsURL(recordID.recordName)) }
    }

    /// After the iCloud account signs out or switches: the old account's tokens and change tags
    /// mean nothing to the next one.
    public func reset() {
        lock.withLock {
            try? FileManager.default.removeItem(at: engineStateURL)
            try? FileManager.default.removeItem(at: systemFieldsDirectory)
        }
    }
}
