import OrionAgent
import OrionCore
import XCTest

@testable import Orion

/// Docs/19 M8: how the app copes with a large repository's snapshot -- import, Explore's model,
/// search, and Ask's context -- timed in the simulator. Opt-in: point
/// `TEST_RUNNER_ORION_LARGE_SNAPSHOT` at an `.orionsnap` (with its manifest beside it), e.g. the
/// structural snapshot of `transformers` (2,638 files, 132,018 symbols).
@MainActor
final class LargeSnapshotTests: XCTestCase {
    func testALargeSnapshotImportsAndLoadsInReasonableTime() async throws {
        guard let path = ProcessInfo.processInfo.environment["ORION_LARGE_SNAPSHOT"],
              FileManager.default.fileExists(atPath: path)
        else { throw XCTSkip("set TEST_RUNNER_ORION_LARGE_SNAPSHOT to a large .orionsnap") }

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("orion-large-\(UUID().uuidString)")
        let inbox = root.appendingPathComponent("Documents")
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = URL(fileURLWithPath: path)
        try FileManager.default.copyItem(at: source, to: inbox.appendingPathComponent(source.lastPathComponent))
        let manifest = source.deletingPathExtension().appendingPathExtension("manifest.json")
        if FileManager.default.fileExists(atPath: manifest.path) {
            try FileManager.default.copyItem(at: manifest, to: inbox.appendingPathComponent(manifest.lastPathComponent))
        }

        let library = LibraryModel(
            library: LocalLibrary(root: root.appendingPathComponent("Library")), inbox: inbox,
            defaults: try XCTUnwrap(UserDefaults(suiteName: "orion-large-\(UUID().uuidString)")))
        var clock = ContinuousClock.now
        await library.importInbox()
        let importTime = clock.duration(to: .now)
        let entry = try XCTUnwrap(library.selected, "\(String(describing: library.message))")

        clock = .now
        let model = try ArchitectureModelLoader.load(outputDirectory: entry.databaseURL.deletingLastPathComponent())
        let loadTime = clock.duration(to: .now)

        clock = .now
        let hits = ExploreHomeList.filter(model.nodes, by: "model")
        let searchTime = clock.duration(to: .now)

        let store = Store(try OrionDatabase(path: entry.databaseURL.path))
        let run = try XCTUnwrap(store.latestRun(commitHash: nil))
        clock = .now
        let context = try await CompactContextBuilder.build(
            store: store, run: run, question: "How does PreTrainedModel load its weights?", budgetTokens: 2_000,
            countTokens: { $0.count / 4 })
        let contextTime = clock.duration(to: .now)

        let databaseBytes = (try FileManager.default.attributesOfItem(atPath: entry.databaseURL.path)[.size] as? Int) ?? 0
        print("""
            LARGE SNAPSHOT: import \(importTime), database \(databaseBytes) bytes
            LARGE SNAPSHOT: architecture model \(loadTime) (\(model.nodes.count) nodes, \(model.edges.count) edges, map drawable \(MapScreen.canDraw(model)))
            LARGE SNAPSHOT: search \(searchTime) (\(hits.count) hits)
            LARGE SNAPSHOT: Ask context \(contextTime) (\(context.count) characters)
            """)
        XCTAssertFalse(MapScreen.canDraw(model), "thousands of modules: list and search, not the map")
        XCTAssertLessThan(importTime, .seconds(60))
        XCTAssertLessThan(loadTime, .seconds(10))
        XCTAssertLessThan(contextTime, .seconds(10))
    }
}
