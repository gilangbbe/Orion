import XCTest
import GRDB
@testable import OrionCodeIntel

/// M3: the pipeline persists `symbols` with parent links and updates `symbol_count`.
final class SymbolPipelineTests: XCTestCase {

    func testPersistsSymbolsAndParentLinks() throws {
        let repo = try TempDir()
        let git = GitRunner(repoPath: repo.url)
        _ = try git.run(["init", "--quiet", "-b", "main"])
        _ = try git.run(["config", "user.email", "t@e.com"])
        _ = try git.run(["config", "user.name", "T"])
        try repo.write("pkg/__init__.py", "from .core import Thing\n")
        try repo.write("pkg/core.py", """
        LIMIT = 5

        class Thing:
            def run(self, n):
                return n

        def helper():
            return Thing()
        """)
        _ = try git.run(["add", "."])
        _ = try git.run(["commit", "--quiet", "-m", "init"])

        let out = try TempDir()
        let database = try OrionDatabase(path: out.path("orion.db"))
        let result = try AnalysisPipeline(database: database).run(
            AnalysisInput(repoPath: repo.url, outputDirectory: out.url, resolve: false)
        )
        XCTAssertGreaterThan(result.symbolCount, 5)

        try database.dbQueue.read { db in
            XCTAssertEqual(try AnalysisRunRecord.fetchOne(db)?.symbolCount, result.symbolCount)

            let all = try SymbolRecord.fetchAll(db)
            func sym(_ anchor: String) -> SymbolRecord? { all.first { $0.anchor == anchor } }

            let module = try XCTUnwrap(sym("pkg/core.py"))
            XCTAssertEqual(module.kind, "module")
            let cls = try XCTUnwrap(sym("pkg/core.py::Thing"))
            XCTAssertEqual(cls.kind, "class")
            XCTAssertEqual(cls.parentSymbolId, module.id)
            let method = try XCTUnwrap(sym("pkg/core.py::Thing.run"))
            XCTAssertEqual(method.kind, "method")
            XCTAssertEqual(method.parentSymbolId, cls.id)
            XCTAssertEqual(sym("pkg/core.py::LIMIT")?.kind, "constant")

            // re-export synthesised in the package __init__
            let reexport = try XCTUnwrap(sym("pkg/__init__.py::Thing"))
            XCTAssertEqual(reexport.kind, "reexport")
            XCTAssertEqual(reexport.redirectsTo, ".core::Thing")

            // every parent_symbol_id resolves to a real row
            let dangling = try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM symbols s
                WHERE s.parent_symbol_id IS NOT NULL
                  AND NOT EXISTS (SELECT 1 FROM symbols p WHERE p.id = s.parent_symbol_id)
                """)
            XCTAssertEqual(dangling, 0)
        }
    }
}
