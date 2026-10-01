import OrionCore
import XCTest

@testable import Orion

/// Docs/19 M4: the iOS library -- inbox import, selection, removal -- and the shared loaders and
/// evidence source reading an imported snapshot on iOS.
@MainActor
final class LibraryModelTests: XCTestCase {
    private var root: URL!
    private var inbox: URL!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("orion-mobile-\(UUID().uuidString)")
        inbox = root.appendingPathComponent("Documents", isDirectory: true)
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        defaults = UserDefaults(suiteName: "orion-mobile-tests-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeModel() -> LibraryModel {
        LibraryModel(
            library: LocalLibrary(root: root.appendingPathComponent("Library")), inbox: inbox, defaults: defaults)
    }

    func testInboxImportInstallsOpensAndCleansUp() async throws {
        let manifest = try SnapshotFixture.write(to: inbox)
        let model = makeModel()
        await model.importInbox()

        XCTAssertEqual(model.entries.map(\.libraryKey), [manifest.libraryKey])
        XCTAssertEqual(model.selectedKey, manifest.libraryKey, "a first import opens the repository")
        XCTAssertEqual(model.entries.first?.manifest.sha256, manifest.sha256)
        XCTAssertEqual(model.message?.isError, false)
        XCTAssertEqual(model.generation, 1)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: inbox.path), [], "inbox emptied")
    }

    func testAFailedInboxImportIsMovedAsideNotRetried() async throws {
        try Data("not a snapshot".utf8).write(to: inbox.appendingPathComponent("broken.orionsnap"))
        let model = makeModel()
        await model.importInbox()

        XCTAssertEqual(model.entries, [])
        XCTAssertEqual(model.message?.isError, true)
        let failed = inbox.appendingPathComponent("Failed Imports")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: failed.path), ["broken.orionsnap"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: inbox.appendingPathComponent("broken.orionsnap").path))
    }

    func testAManifestThatDoesNotMatchIsRefused() async throws {
        try SnapshotFixture.write(to: inbox)
        var tampered = try KnowledgeSnapshotManifest.decode(
            Data(contentsOf: inbox.appendingPathComponent("demo.manifest.json")))
        tampered.sha256 = String(repeating: "0", count: 64)
        try tampered.json().write(to: inbox.appendingPathComponent("demo.manifest.json"))
        let model = makeModel()
        await model.importInbox()
        XCTAssertEqual(model.entries, [])
        XCTAssertEqual(model.message?.isError, true)
    }

    func testSelectionPersistsAndRemovalClearsIt() async throws {
        let manifest = try SnapshotFixture.write(to: inbox)
        let first = makeModel()
        await first.importInbox()

        let relaunched = makeModel()
        relaunched.refresh()
        XCTAssertEqual(relaunched.selected?.libraryKey, manifest.libraryKey)

        relaunched.remove(try XCTUnwrap(relaunched.selected))
        XCTAssertNil(relaunched.selectedKey)
        XCTAssertEqual(relaunched.entries, [])
    }

    // MARK: - From iCloud (Docs/19 M5)

    private func cloudSnapshot() throws -> (URL, KnowledgeSnapshotManifest) {
        let downloads = root.appendingPathComponent("Incoming", isDirectory: true)
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        let manifest = try SnapshotFixture.write(to: downloads, withManifest: false)
        return (downloads.appendingPathComponent("demo.orionsnap"), manifest)
    }

    func testCloudInstallSkipsTheSnapshotAlreadyInstalled() async throws {
        let (file, manifest) = try cloudSnapshot()
        let model = makeModel()
        try await model.installFromCloud(file, manifest: manifest)
        XCTAssertEqual(model.entries.map(\.libraryKey), [manifest.libraryKey])
        XCTAssertEqual(model.generation, 1)

        // The same record fetched again (e.g. after a relaunch) must not rebuild the repository.
        try await model.installFromCloud(file, manifest: manifest)
        XCTAssertEqual(model.generation, 1)
    }

    func testMacStoppingSyncKeepsTheRepositoryAndMarksIt() async throws {
        let (file, manifest) = try cloudSnapshot()
        let model = makeModel()
        try await model.installFromCloud(file, manifest: manifest)
        model.markNoLongerSynced(manifest.libraryKey)
        XCTAssertEqual(model.noLongerSynced, [manifest.libraryKey])
        XCTAssertEqual(model.entries.count, 1, "the device keeps its copy")
        XCTAssertEqual(makeModel().noLongerSynced, [manifest.libraryKey], "remembered across launches")

        // Syncing it again clears the mark.
        try await model.installFromCloud(file, manifest: manifest)
        XCTAssertEqual(model.noLongerSynced, [])
    }

    func testABadCloudSnapshotThrowsSoTheReceiverCanReportIt() async throws {
        let (file, manifest) = try cloudSnapshot()
        try Data("garbage".utf8).write(to: file)
        let model = makeModel()
        do {
            try await model.installFromCloud(file, manifest: manifest)
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(model.entries, [])
        }
    }

    // MARK: - Shared code on iOS

    func testDatabasesOpenAsImportedSnapshotsOnIOS() {
        XCTAssertEqual(OrionDatabase.OpenMode.platformDefault, .importedSnapshot)
    }

    func testSharedLoadersReadAnImportedSnapshot() async throws {
        try SnapshotFixture.write(to: inbox)
        let model = makeModel()
        await model.importInbox()
        let folder = try XCTUnwrap(model.selected).databaseURL.deletingLastPathComponent()

        let architecture = try ArchitectureModelLoader.load(outputDirectory: folder)
        guard case .semantic(_, let componentCount, _) = architecture.layer else {
            return XCTFail("expected the semantic layer, got \(architecture.layer)")
        }
        XCTAssertEqual(componentCount, 1)
        let node = try XCTUnwrap(architecture.nodes.first)
        XCTAssertEqual(node.name, "App Core")

        let detail = try ComponentDetailLoader.load(outputDirectory: folder, node: node, layer: architecture.layer)
        XCTAssertEqual(detail.members.map(\.anchor), [SnapshotFixture.anchor])
        XCTAssertEqual(try ModelChangeLoader.load(outputDirectory: folder), [])
    }

    func testSnapshotEvidenceSourceShowsTheSnippetOrSaysItIsMissing() async throws {
        try SnapshotFixture.write(to: inbox)
        let model = makeModel()
        await model.importInbox()
        let source = SnapshotEvidenceSource(
            outputDirectory: try XCTUnwrap(model.selected).databaseURL.deletingLastPathComponent())

        let snippet = try source.snippet(for: EvidenceDetail(id: "e", anchor: SnapshotFixture.anchor, startLine: 20, endLine: 22))
        XCTAssertEqual(snippet.filePath, "pkg/app.py")
        XCTAssertEqual(snippet.lines.first, SourceLine(number: 17, text: "line 17"))
        XCTAssertEqual(snippet.highlightRange, 20...22)
        XCTAssertFalse(snippet.truncated)

        XCTAssertThrowsError(
            try source.snippet(for: EvidenceDetail(id: "x", anchor: "pkg/other.py::f", startLine: 1, endLine: 2))
        ) { error in
            guard case EvidenceSourceError.notInSnapshot("pkg/other.py") = error else {
                return XCTFail("\(error)")
            }
        }
    }
}
