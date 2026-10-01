import CloudKit
import Foundation
import Observation
import OrionCodeIntel
import OrionSync

/// "Sync to iPhone" (Docs/19 M5): per repository, publish its knowledge snapshot to the user's
/// private iCloud, where the iOS companion picks it up.
///
/// - Off by default for every repository. What's uploaded includes the source lines evidence cites
///   (Docs/19 M2), so it's the user's call per repository, and the UI says so.
/// - The `SnapshotPublisher` (and with it CloudKit) is only created once something is switched
///   on, so a Mac that never syncs never touches iCloud.
/// - A publish rebuilds the snapshot from what the app shows (`KnowledgeSnapshotBuilder`) and
///   uploads it only when the knowledge changed -- a different run, or different counts --
///   because reopening a repository would otherwise re-upload the same snapshot every launch.
@MainActor
@Observable
final class IPhoneSync {
    static let shared = IPhoneSync()

    enum State: Equatable {
        case off
        case preparing
        case pending
        case uploaded(Date)
        case failed(String)
    }

    private(set) var states: [String: State] = [:]
    private var enabled: Set<String>
    private var publisher: SnapshotPublisher?
    private let defaults: UserDefaults
    private let container = CKContainer(identifier: SnapshotCloud.containerIdentifier)
    private static let enabledKey = "Orion.syncToIPhone.libraryKeys"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.enabled = Set(defaults.stringArray(forKey: Self.enabledKey) ?? [])
    }

    func isEnabled(_ libraryKey: String) -> Bool { enabled.contains(libraryKey) }

    func state(for libraryKey: String) -> State {
        states[libraryKey] ?? (isEnabled(libraryKey) ? .pending : .off)
    }

    /// The repository's `libraryKey` (its CloudKit record name), from the run the app shows.
    nonisolated static func libraryKey(outputDirectory: URL) throws -> String? {
        let store = Store(try OrionDatabase(path: outputDirectory.appendingPathComponent("orion.db").path))
        guard let run = try store.latestRun(commitHash: nil), let repository = try store.repository(id: run.repositoryId)
        else { return nil }
        return KnowledgeSnapshotFormat.libraryKey(sourceURL: repository.sourceURL, localPath: repository.localPath)
    }

    // MARK: - Switching

    func setEnabled(_ on: Bool, libraryKey: String, repoRoot: URL, outputDirectory: URL) async {
        if on {
            enabled.insert(libraryKey)
            persist()
            await publish(libraryKey: libraryKey, repoRoot: repoRoot, outputDirectory: outputDirectory, force: true)
        } else {
            enabled.remove(libraryKey)
            persist()
            states[libraryKey] = .off
            // Not `publisher?`: on a fresh launch nothing has started the publisher yet, and
            // switching off must still delete the iCloud record (a Docs/19 M5 bug, caught live).
            guard (try? await container.accountStatus()) == .available else { return }
            let publisher = publisherOrStart()
            publisher.unpublish(libraryKey: libraryKey)
            try? await publisher.sendNow()
            states[libraryKey] = .off
        }
    }

    /// After an analysis, a Build Architecture Model run, or opening the repository: republish if
    /// this repository syncs and its knowledge changed.
    func publishIfEnabled(repoRoot: URL, outputDirectory: URL) async {
        guard let key = try? Self.libraryKey(outputDirectory: outputDirectory), isEnabled(key) else { return }
        await publish(libraryKey: key, repoRoot: repoRoot, outputDirectory: outputDirectory, force: false)
    }

    /// "Sync Now": rebuild and upload even if nothing seems to have changed.
    func syncNow(libraryKey: String, repoRoot: URL, outputDirectory: URL) async {
        await publish(libraryKey: libraryKey, repoRoot: repoRoot, outputDirectory: outputDirectory, force: true)
    }

    // MARK: - Publishing

    private func publish(libraryKey: String, repoRoot: URL, outputDirectory: URL, force: Bool) async {
        guard (try? await container.accountStatus()) == .available else {
            states[libraryKey] = .failed("Sign in to iCloud on this Mac to sync to your iPhone.")
            return
        }
        let publisher = publisherOrStart()
        states[libraryKey] = .preparing
        do {
            let staged = try? publisher.outbox.entry(libraryKey: libraryKey).manifest
            let built = try await Task.detached(priority: .utility) { () -> (URL, KnowledgeSnapshotManifest, URL) in
                let work = FileManager.default.temporaryDirectory
                    .appendingPathComponent("orion-sync-\(UUID().uuidString)", isDirectory: true)
                let output = try KnowledgeSnapshotBuilder(
                    databasePath: outputDirectory.appendingPathComponent("orion.db"), repoRoot: repoRoot
                ).build(to: work)
                return (output.snapshotURL, output.manifest, work)
            }.value
            defer { try? FileManager.default.removeItem(at: built.2) }
            if !force, let staged, Self.sameKnowledge(staged, built.1) {
                if case .preparing = states[libraryKey] { states[libraryKey] = .pending }
                try? await publisher.sendNow()
                return
            }
            try publisher.publish(snapshot: built.0, manifest: built.1)
            try await publisher.sendNow()
        } catch {
            states[libraryKey] = .failed(error.localizedDescription)
        }
    }

    /// Same run and same amounts of knowledge: nothing the phone would see differently.
    nonisolated static func sameKnowledge(_ a: KnowledgeSnapshotManifest, _ b: KnowledgeSnapshotManifest) -> Bool {
        a.runId == b.runId && a.commitHash == b.commitHash && a.counts == b.counts
    }

    #if DEBUG
    /// Unbuffered (stderr), so the launch hook's output survives the process being stopped.
    private static func log(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }

    /// `ORION_SYNC_PUBLISH=<repository path>` at launch: switch sync on for that (already analyzed)
    /// repository and publish it -- or, with `ORION_SYNC_ACTION=unpublish`, switch it off and
    /// delete its iCloud record -- printing the outcome -- how Docs/19 M5's end-to-end check runs
    /// without clicking through the UI. Env var, not a positional argument: AppKit would treat
    /// that as a file to open.
    func publishFromLaunchEnvironment() async {
        guard let path = ProcessInfo.processInfo.environment["ORION_SYNC_PUBLISH"], !path.isEmpty else { return }
        let repoRoot = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
        let outputDirectory = repoRoot.appendingPathComponent(".orion", isDirectory: true)
        guard let key = try? Self.libraryKey(outputDirectory: outputDirectory) else {
            Self.log("[ORION_SYNC_PUBLISH] no analyzed run at \(outputDirectory.path)")
            return
        }
        if ProcessInfo.processInfo.environment["ORION_SYNC_ACTION"] == "unpublish" {
            // Switch sync off: deletes the iCloud record; the iPhone keeps its copy.
            await setEnabled(false, libraryKey: key, repoRoot: repoRoot, outputDirectory: outputDirectory)
            Self.log("[ORION_SYNC_PUBLISH] \(key): unpublished")
            return
        }
        Self.log("[ORION_SYNC_PUBLISH] publishing \(repoRoot.lastPathComponent) as \(key)")
        await setEnabled(true, libraryKey: key, repoRoot: repoRoot, outputDirectory: outputDirectory)
        for _ in 0..<120 {
            if case .uploaded = state(for: key) { break }
            if case .failed = state(for: key) { break }
            try? await Task.sleep(for: .seconds(1))
        }
        Self.log("[ORION_SYNC_PUBLISH] \(key): \(state(for: key))")
    }
    #endif

    private func publisherOrStart() -> SnapshotPublisher {
        if let publisher { return publisher }
        let directory = AppPaths.applicationSupportDirectory.appendingPathComponent("Sync", isDirectory: true)
        let publisher = SnapshotPublisher(
            directory: directory, database: container.privateCloudDatabase
        ) { [weak self] key, status in
            Task { @MainActor in
                switch status {
                case .pending: self?.states[key] = .pending
                case .uploaded(let date): self?.states[key] = .uploaded(date)
                case .failed(let message): self?.states[key] = .failed(message)
                }
            }
        }
        self.publisher = publisher
        return publisher
    }

    private func persist() {
        defaults.set(Array(enabled).sorted(), forKey: Self.enabledKey)
    }
}
