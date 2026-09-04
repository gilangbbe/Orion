import XCTest
@testable import OrionCodeIntel

/// M7 against vendored Starlette: the export honours the Phase 2 join contract, and a
/// stable slice of `code_graph.json` is pinned as a golden snapshot.
final class StarletteExportTests: XCTestCase {

    private static var exportDir: URL?
    private static var keepAlive: [TempDir] = []

    private func export() throws -> URL {
        if let dir = Self.exportDir { return dir }
        try TestPaths.requireStarlette()
        try TestPaths.requireNpx()
        let out = try TempDir()
        Self.keepAlive.append(out)
        let db = try OrionDatabase(path: out.path("orion.db"))
        let result = try AnalysisPipeline(database: db).run(
            AnalysisInput(repoPath: TestPaths.vendoredStarlette, outputDirectory: out.url)
        )
        let dir = try XCTUnwrap(result.exportPath)
        Self.exportDir = dir
        return dir
    }

    private func benchmarkRelevantSymbols() throws -> [String] {
        let url = TestPaths.orionRepoRoot
            .appendingPathComponent("Agent Feasibility Study/benchmark/benchmark.resolved.json")
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
        let items = (json as? [[String: Any]]) ?? ((json as? [String: Any])?["questions"] as? [[String: Any]]) ?? []
        return items.flatMap { ($0["relevant_symbols"] as? [String]) ?? [] }
            .filter { $0.contains("::") && $0.split(separator: ":").first?.hasSuffix(".py") == true }
    }

    func testSymbolsJsonlHonoursBenchmarkAnchors() throws {
        let dir = try export()
        let anchors = try Set(
            String(contentsOf: dir.appendingPathComponent("symbols.jsonl"), encoding: .utf8)
                .split(separator: "\n")
                .map { line -> String in
                    let o = try JSONSerialization.jsonObject(with: Data(line.utf8)) as! [String: Any]
                    return o["anchor"] as! String
                }
        )
        let wanted = try benchmarkRelevantSymbols()
        XCTAssertGreaterThan(wanted.count, 100)
        let present = wanted.filter { anchors.contains($0) }.count
        XCTAssertGreaterThanOrEqual(
            Double(present) / Double(wanted.count), 0.95,
            "benchmark relevant_symbols present in symbols.jsonl: \(present)/\(wanted.count)"
        )
    }

    func testCodeGraphGoldenSnapshot() throws {
        let dir = try export()
        let g = try JSONSerialization.jsonObject(
            with: Data(contentsOf: dir.appendingPathComponent("code_graph.json"))
        ) as! [String: Any]

        // stable slice
        var classBases: [String: [String]] = [:]
        for c in (g["classes"] as? [[String: Any]]) ?? [] {
            let bases = (c["bases"] as? [String]) ?? []
            if !bases.isEmpty { classBases[c["anchor"] as! String] = bases.sorted() }
        }
        var moduleImports: [String: [String]] = [:]
        for m in (g["modules"] as? [[String: Any]]) ?? [] {
            moduleImports[m["module_path"] as! String] = ((m["imports"] as? [String]) ?? []).sorted()
        }
        let slice: [String: Any] = [
            "symbols_by_kind": (g["stats"] as! [String: Any])["symbols_by_kind"]!,
            "relationships_by_type": (g["stats"] as! [String: Any])["relationships_by_type"]!,
            "class_bases": classBases,
            "module_imports": moduleImports,
        ]
        let sliceData = try JSONSerialization.data(
            withJSONObject: slice, options: [.sortedKeys, .prettyPrinted]
        )

        let snapshotURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Snapshots/starlette_code_graph.json")

        let update = ProcessInfo.processInfo.environment["ORION_UPDATE_SNAPSHOTS"] == "1"
        if update || !FileManager.default.fileExists(atPath: snapshotURL.path) {
            try FileManager.default.createDirectory(
                at: snapshotURL.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try sliceData.write(to: snapshotURL)
            if !update {
                XCTFail("wrote missing snapshot \(snapshotURL.lastPathComponent); rerun to compare")
            }
            return
        }

        let expected = try Data(contentsOf: snapshotURL)
        XCTAssertEqual(
            String(decoding: sliceData, as: UTF8.self),
            String(decoding: expected, as: UTF8.self),
            "code_graph.json slice drifted; set ORION_UPDATE_SNAPSHOTS=1 to accept"
        )
    }
}
