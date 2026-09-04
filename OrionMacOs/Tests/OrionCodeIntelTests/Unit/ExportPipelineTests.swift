import XCTest
@testable import OrionCodeIntel

/// M7: `analyze` writes a deterministic `export/`, and `orion-index export` regenerates it
/// from the DB alone.
final class ExportPipelineTests: XCTestCase {

    private func buildRepo() throws -> TempDir {
        let repo = try TempDir()
        let git = GitRunner(repoPath: repo.url)
        _ = try git.run(["init", "--quiet", "-b", "main"])
        _ = try git.run(["config", "user.email", "t@e.com"])
        _ = try git.run(["config", "user.name", "T"])
        try repo.write("pyproject.toml", "[project]\nname = \"demo\"\ndependencies = [\"anyio\"]\n")
        try repo.write("demo/__init__.py", "")
        try repo.write("demo/core.py", """
        import anyio

        class Widget:
            def run(self):
                return 1
        """)
        _ = try git.run(["add", "."])
        _ = try git.run(["commit", "--quiet", "-m", "init"])
        return repo
    }

    func testAnalyzeWritesExport() throws {
        let repo = try buildRepo()
        let out = try TempDir()
        let db = try OrionDatabase(path: out.path("orion.db"))
        let result = try AnalysisPipeline(database: db).run(
            AnalysisInput(repoPath: repo.url, outputDirectory: out.url, resolve: false)
        )
        let exportDir = try XCTUnwrap(result.exportPath)

        for name in ["repository.json", "files.jsonl", "symbols.jsonl", "relationships.jsonl",
                     "external_dependencies.jsonl", "diagnostics.jsonl", "code_graph.json"] {
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: exportDir.appendingPathComponent(name).path),
                "missing \(name)"
            )
        }

        // symbols.jsonl: benchmark-form anchor present, snake_case keys, valid JSON per line
        let symbolLines = try String(
            contentsOf: exportDir.appendingPathComponent("symbols.jsonl"), encoding: .utf8
        ).split(separator: "\n")
        let anchors = try symbolLines.map { line -> String in
            let obj = try JSONSerialization.jsonObject(with: Data(line.utf8)) as! [String: Any]
            XCTAssertNotNil(obj["qualified_name"])   // snake_case
            return obj["anchor"] as! String
        }
        XCTAssertTrue(anchors.contains("demo/core.py::Widget.run"))
        XCTAssertTrue(anchors.contains("demo/core.py"))   // module symbol
    }

    func testExportIsDeterministic() throws {
        let repo = try buildRepo()
        let out = try TempDir()
        let db = try OrionDatabase(path: out.path("orion.db"))
        _ = try AnalysisPipeline(database: db).run(
            AnalysisInput(repoPath: repo.url, outputDirectory: out.url, resolve: false, export: false)
        )

        let first = try CodeGraphExporter(store: Store(db)).export(to: out.url)
        let snapshot = try FileManager.default.contentsOfDirectory(atPath: first.path).sorted()
            .map { try Data(contentsOf: first.appendingPathComponent($0)) }

        let second = try CodeGraphExporter(store: Store(db)).export(to: out.url)
        let again = try FileManager.default.contentsOfDirectory(atPath: second.path).sorted()
            .map { try Data(contentsOf: second.appendingPathComponent($0)) }

        XCTAssertEqual(snapshot, again)
    }

    func testCodeGraphJSONShape() throws {
        let repo = try buildRepo()
        let out = try TempDir()
        let db = try OrionDatabase(path: out.path("orion.db"))
        let result = try AnalysisPipeline(database: db).run(
            AnalysisInput(repoPath: repo.url, outputDirectory: out.url, resolve: false)
        )
        let data = try Data(contentsOf: result.exportPath!.appendingPathComponent("code_graph.json"))
        let g = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertNotNil(g["repository"])
        XCTAssertNotNil((g["stats"] as? [String: Any])?["symbols_by_kind"])
        let modules = try XCTUnwrap(g["modules"] as? [[String: Any]])
        XCTAssertTrue(modules.contains { $0["module_path"] as? String == "demo.core" })
    }
}
