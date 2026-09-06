import XCTest
import OrionCodeIntel

@testable import OrionAgent

/// `AgentTool` wrappers over a real, small analyzed repo -- same fixture pattern as
/// `OrionCodeIntelTests/Unit/QueryEngineTests.swift` (duplicated, not shared across test
/// targets in this package).
final class QueryEngineToolsTests: XCTestCase {

    private var keepAlive: [TempDir] = []

    private func analyzed() throws -> OrionDatabase {
        let repo = try TempDir()
        keepAlive.append(repo)
        let git = GitRunner(repoPath: repo.url)
        _ = try git.run(["init", "--quiet", "-b", "main"])
        _ = try git.run(["config", "user.email", "t@e.com"])
        _ = try git.run(["config", "user.name", "T"])
        try repo.write("pkg/__init__.py", "")
        try repo.write(
            "pkg/a.py", "from pkg import b\n\nclass Widget:\n    def run(self):\n        return 1\n")
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

    func testLookupSymbolToolFindsRealSymbol() throws {
        let tool = LookupSymbolTool(engine: QueryEngine(try analyzed()), commit: nil)
        let result = tool.execute(arguments: ["query": "Widget"])
        XCTAssertTrue(result.contains("pkg/a.py::Widget"))
        XCTAssertTrue(result.contains("class"))
    }

    func testLookupSymbolToolMissingArgument() throws {
        let tool = LookupSymbolTool(engine: QueryEngine(try analyzed()), commit: nil)
        let result = tool.execute(arguments: [:])
        XCTAssertTrue(result.hasPrefix("Error:"))
    }

    func testLookupSymbolToolNoMatches() throws {
        let tool = LookupSymbolTool(engine: QueryEngine(try analyzed()), commit: nil)
        let result = tool.execute(arguments: ["query": "NoSuchSymbolAnywhere"])
        XCTAssertTrue(result.contains("No symbols found"))
    }

    func testModuleSymbolsToolListsRealModule() throws {
        let tool = ModuleSymbolsTool(engine: QueryEngine(try analyzed()), commit: nil)
        let result = tool.execute(arguments: ["module": "pkg.a"])
        XCTAssertTrue(result.contains("pkg/a.py::Widget"))
    }

    func testCalleesToolShowsImportEdge() throws {
        let tool = CalleesTool(engine: QueryEngine(try analyzed()), commit: nil)
        let result = tool.execute(arguments: ["anchor": "pkg/a.py"])
        XCTAssertTrue(result.contains("imports"))
        XCTAssertTrue(result.contains("pkg/b.py"))
    }

    func testCallersToolShowsInboundImportEdge() throws {
        let tool = CallersTool(engine: QueryEngine(try analyzed()), commit: nil)
        let result = tool.execute(arguments: ["anchor": "pkg/b.py"])
        XCTAssertTrue(result.contains("imports"))
        XCTAssertTrue(result.contains("pkg/a.py"))
    }

    func testCallersToolUnknownAnchor() throws {
        let tool = CallersTool(engine: QueryEngine(try analyzed()), commit: nil)
        let result = tool.execute(arguments: ["anchor": "nope.py::Nope"])
        XCTAssertTrue(result.contains("No callers found"))
    }

    func testAllReturnsFourDistinctTools() throws {
        let tools = QueryEngineTools.all(engine: QueryEngine(try analyzed()))
        XCTAssertEqual(Set(tools.map { $0.name }).count, 4)
    }
}
