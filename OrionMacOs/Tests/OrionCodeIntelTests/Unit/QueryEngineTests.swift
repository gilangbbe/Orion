import XCTest
@testable import OrionCodeIntel

final class QueryEngineTests: XCTestCase {

    private func analyzed() throws -> OrionDatabase {
        let repo = try TempDir()
        keepAlive.append(repo)
        let git = GitRunner(repoPath: repo.url)
        _ = try git.run(["init", "--quiet", "-b", "main"])
        _ = try git.run(["config", "user.email", "t@e.com"])
        _ = try git.run(["config", "user.name", "T"])
        try repo.write("pkg/__init__.py", "")
        try repo.write("pkg/a.py", "from pkg import b\n\nclass Widget:\n    def run(self):\n        return 1\n")
        try repo.write("pkg/b.py", "VALUE = 1\n")
        _ = try git.run(["add", "."])
        _ = try git.run(["commit", "--quiet", "-m", "init"])

        let out = try TempDir()
        keepAlive.append(out)
        let db = try OrionDatabase(path: out.path("orion.db"))
        _ = try AnalysisPipeline(database: db).run(
            AnalysisInput(repoPath: repo.url, outputDirectory: out.url, resolve: false, export: false)
        )
        return db
    }
    private var keepAlive: [TempDir] = []

    func testFindSymbols() throws {
        let engine = QueryEngine(try analyzed())
        let hits = try engine.findSymbols(matching: "Widget", commit: nil, limit: 10)
        XCTAssertTrue(hits.contains { $0.anchor == "pkg/a.py::Widget" && $0.kind == "class" })
        XCTAssertTrue(hits.contains { $0.anchor == "pkg/a.py::Widget.run" })
    }

    func testModuleSymbols() throws {
        let engine = QueryEngine(try analyzed())
        let hits = try engine.moduleSymbols("pkg.a", commit: nil, limit: 50)
        XCTAssertTrue(hits.allSatisfy { $0.file == "pkg/a.py" })
        XCTAssertTrue(hits.contains { $0.anchor == "pkg/a.py" && $0.kind == "module" })
    }

    func testCalleesShowsImportEdge() throws {
        let engine = QueryEngine(try analyzed())
        // pkg.a module imports pkg.b
        let out = try engine.callees(of: "pkg/a.py", commit: nil, limit: 50)
        XCTAssertTrue(out.contains { $0.type == "imports" && $0.anchor == "pkg/b.py" })
    }

    func testCallersOfImportedModule() throws {
        let engine = QueryEngine(try analyzed())
        let inbound = try engine.callers(of: "pkg/b.py", commit: nil, limit: 50)
        XCTAssertTrue(inbound.contains { $0.type == "imports" && $0.anchor == "pkg/a.py" })
    }

    func testEmptyOnUnknownAnchor() throws {
        let engine = QueryEngine(try analyzed())
        XCTAssertTrue(try engine.callees(of: "nope.py::Nope", commit: nil, limit: 10).isEmpty)
    }
}
