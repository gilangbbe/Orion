import Foundation
import Observation
import OrionCore

/// The repositories on this device and which one is open (Docs/19 M4).
///
/// Snapshots arrive two ways until CloudKit sync (M5):
/// - **The Files picker** ("Import Snapshot…").
/// - **The app's Documents folder**, which Finder's file sharing, `devicectl device copy to`, or
///   `simctl` can write into. Any `*.orionsnap` there is imported when the app becomes active,
///   checked against a `<name>.manifest.json` beside it when one exists, then removed. One that
///   fails moves to `Documents/Failed Imports/`, so it isn't retried every launch.
@MainActor
@Observable
final class LibraryModel {
    struct Message: Equatable {
        let text: String
        let isError: Bool
    }

    let library: LocalLibrary
    let inbox: URL
    private let defaults: UserDefaults
    private static let selectionKey = "OrionMobile.selectedLibraryKey"

    private(set) var entries: [LocalLibrary.Entry] = []
    /// Repositories the Mac stopped syncing (its record was deleted from iCloud). The device keeps
    /// them; the Library just stops calling them synced.
    private(set) var noLongerSynced: Set<String>
    private static let noLongerSyncedKey = "OrionMobile.noLongerSyncedLibraryKeys"
    private(set) var isImporting = false
    private(set) var message: Message?
    /// Bumped by every import, so screens showing a repository reload its knowledge.
    private(set) var generation = 0

    var selectedKey: String? {
        didSet { defaults.set(selectedKey, forKey: Self.selectionKey) }
    }

    var selected: LocalLibrary.Entry? {
        entries.first { $0.libraryKey == selectedKey }
    }

    init(library: LocalLibrary, inbox: URL, defaults: UserDefaults = .standard) {
        self.library = library
        self.inbox = inbox
        self.defaults = defaults
        self.selectedKey = defaults.string(forKey: Self.selectionKey)
        self.noLongerSynced = Set(defaults.stringArray(forKey: Self.noLongerSyncedKey) ?? [])
    }

    /// The real locations: `Application Support/Orion/Library` and the app's Documents folder.
    static func live() -> LibraryModel {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let root = (try? LocalLibrary.defaultRoot())
            ?? documents.deletingLastPathComponent().appendingPathComponent("Library/Application Support/Orion/Library")
        return LibraryModel(library: LocalLibrary(root: root), inbox: documents)
    }

    func refresh() {
        entries = (try? library.entries()) ?? []
        if selected == nil { selectedKey = entries.first?.libraryKey }
    }

    func dismissMessage() {
        message = nil
    }

    // MARK: - Importing

    /// A file the user picked. It may be security-scoped (iCloud Drive, another app's folder), so
    /// it's copied out first; a `.manifest.json` beside it is used when readable.
    func importPickedFile(_ url: URL) async {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("orion-import-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        do {
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            let copy = staging.appendingPathComponent(url.lastPathComponent)
            try FileManager.default.copyItem(at: url, to: copy)
            let manifest = Self.siblingManifest(of: url)
            _ = await install(copy, expected: manifest)
        } catch {
            message = Message(text: "Couldn't read \(url.lastPathComponent): \(error.localizedDescription)", isError: true)
        }
    }

    /// Every `*.orionsnap` waiting in the inbox (Documents).
    func importInbox() async {
        let files = ((try? FileManager.default.contentsOfDirectory(at: inbox, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == KnowledgeSnapshotFormat.fileExtension }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        for file in files {
            let manifestURL = Self.manifestURL(besides: file)
            let succeeded = await install(file, expected: Self.siblingManifest(of: file))
            if succeeded {
                try? FileManager.default.removeItem(at: file)
                try? FileManager.default.removeItem(at: manifestURL)
            } else {
                let failed = inbox.appendingPathComponent("Failed Imports", isDirectory: true)
                try? FileManager.default.createDirectory(at: failed, withIntermediateDirectories: true)
                for url in [file, manifestURL] where FileManager.default.fileExists(atPath: url.path) {
                    let target = failed.appendingPathComponent(url.lastPathComponent)
                    try? FileManager.default.removeItem(at: target)
                    try? FileManager.default.moveItem(at: url, to: target)
                }
            }
        }
    }

    // MARK: - From iCloud (Docs/19 M5)

    struct CloudInstallFailed: Error, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// A snapshot `CloudSync` received. Skipped when it's the one already installed (the same
    /// sha256), so a fetch that returns an unchanged record doesn't rebuild the repository.
    func installFromCloud(_ file: URL, manifest: KnowledgeSnapshotManifest) async throws {
        setSynced(manifest.libraryKey, true)
        if let current = entries.first(where: { $0.libraryKey == manifest.libraryKey }),
           current.manifest.sha256 == manifest.sha256 {
            return
        }
        guard await install(file, expected: manifest) else {
            throw CloudInstallFailed(message: message?.text ?? "Couldn't install the snapshot from iCloud.")
        }
    }

    func markNoLongerSynced(_ libraryKey: String) {
        setSynced(libraryKey, false)
    }

    private func setSynced(_ libraryKey: String, _ synced: Bool) {
        if synced { noLongerSynced.remove(libraryKey) } else { noLongerSynced.insert(libraryKey) }
        defaults.set(Array(noLongerSynced).sorted(), forKey: Self.noLongerSyncedKey)
    }

    /// Runs the importer off the main actor, then refreshes. A first import opens the repository.
    private func install(_ file: URL, expected: KnowledgeSnapshotManifest?) async -> Bool {
        isImporting = true
        defer { isImporting = false }
        let library = library
        do {
            let report = try await Task.detached(priority: .userInitiated) {
                try KnowledgeSnapshotImporter(library: library).importSnapshot(at: file, expected: expected)
            }.value
            generation += 1
            refresh()
            if !report.replacedExisting || selected == nil { selectedKey = report.manifest.libraryKey }
            message = Message(text: Self.summary(report), isError: false)
            return true
        } catch {
            message = Message(
                text: "Couldn't import \(file.lastPathComponent): \(error.localizedDescription)", isError: true)
            return false
        }
    }

    // MARK: - Removing

    /// Deletes the repository and everything learned and asked about it on this device.
    func remove(_ entry: LocalLibrary.Entry) {
        do {
            try library.remove(libraryKey: entry.libraryKey)
            if selectedKey == entry.libraryKey { selectedKey = nil }
            setSynced(entry.libraryKey, true)
            refresh()
        } catch {
            message = Message(text: "Couldn't remove \(entry.manifest.repositoryName): \(error.localizedDescription)", isError: true)
        }
    }

    // MARK: - Helpers

    static func summary(_ report: KnowledgeSnapshotImporter.Report) -> String {
        let name = "\(report.manifest.repositoryName) @ \(report.manifest.commitHash.prefix(8))"
        guard report.replacedExisting else { return "Added \(name)." }
        let kept = (report.carried["teaching_attempts"] ?? 0) + (report.carried["ask_sessions"] ?? 0)
        return kept > 0 ? "Updated \(name) — your answers and questions came along." : "Updated \(name)."
    }

    private static func manifestURL(besides file: URL) -> URL {
        file.deletingPathExtension().appendingPathExtension("manifest.json")
    }

    private static func siblingManifest(of file: URL) -> KnowledgeSnapshotManifest? {
        (try? Data(contentsOf: manifestURL(besides: file))).flatMap { try? KnowledgeSnapshotManifest.decode($0) }
    }
}
