import CloudKit
import Foundation
import Observation
import OrionCore
import OrionSync
import UIKit

/// iCloud sync on the iPhone (Docs/19 M5): receives the knowledge snapshots Orion on the Mac
/// publishes ("Sync to iPhone") and installs them into the library.
///
/// Gated on the iCloud account, as CloudKit work must be: with no account the Library says so
/// instead of failing silently. `CKSyncEngine` (inside `SnapshotReceiver`) subscribes to the
/// private database and fetches on push; this also fetches at launch, on returning to the
/// foreground, and on pull-to-refresh.
@MainActor
@Observable
final class CloudSync {
    enum Account: Equatable {
        case unknown, available, noAccount, restricted, temporarilyUnavailable
    }

    private(set) var account: Account = .unknown
    private(set) var status: SnapshotReceiver.Status = .idle

    private var receiver: SnapshotReceiver?
    private weak var library: LibraryModel?
    private let container = CKContainer(identifier: SnapshotCloud.containerIdentifier)

    /// Unit tests run inside the app; they must never reach for iCloud.
    static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    func start(library: LibraryModel) async {
        guard !Self.isRunningTests else { return }
        self.library = library
        NotificationCenter.default.addObserver(forName: .CKAccountChanged, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
        await refresh()
    }

    /// Re-checks the account and fetches -- launch, foreground, pull-to-refresh.
    func refresh() async {
        guard !Self.isRunningTests, let library else { return }
        account = await currentAccount()
        guard account == .available else {
            status = .idle
            return
        }
        let receiver = receiver ?? makeReceiver(library: library)
        self.receiver = receiver
        try? await receiver.fetchNow()
    }

    private func currentAccount() async -> Account {
        switch try? await container.accountStatus() {
        case .available: .available
        case .noAccount: .noAccount
        case .restricted: .restricted
        case .temporarilyUnavailable: .temporarilyUnavailable
        default: .unknown
        }
    }

    private func makeReceiver(library: LibraryModel) -> SnapshotReceiver {
        let directory = (try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            .map { $0.appendingPathComponent("Orion/Sync", isDirectory: true) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("OrionSync", isDirectory: true)
        return SnapshotReceiver(
            directory: directory, database: container.privateCloudDatabase,
            install: { [weak library] file, manifest in
                try await library?.installFromCloud(file, manifest: manifest)
            },
            removed: { [weak library] libraryKey in
                await library?.markNoLongerSynced(libraryKey)
            },
            onStatus: { [weak self] status in
                Task { @MainActor in self?.status = status }
            })
    }
}

/// Registers for the silent pushes `CKSyncEngine`'s database subscription sends when the Mac
/// publishes, so a new snapshot can arrive while the app is in the background.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        if !CloudSync.isRunningTests { application.registerForRemoteNotifications() }
        return true
    }
}
