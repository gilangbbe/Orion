import XCTest
import GRDB
@testable import OrionCodeIntel

/// M5: the pipeline runs scip-python and emits `calls` / `extends` edges — and degrades
/// cleanly when resolution is turned off.
final class ScipResolutionPipelineTests: XCTestCase {

    private func makeRepo() throws -> TempDir {
        let repo = try TempDir()
        let git = GitRunner(repoPath: repo.url)
        _ = try git.run(["init", "--quiet", "-b", "main"])
        _ = try git.run(["config", "user.email", "t@e.com"])
        _ = try git.run(["config", "user.name", "T"])
        try repo.write("pyproject.toml", """
        [project]
        name = "demo"
        version = "0.1.0"
        [tool.pyright]
        include = ["demo"]
        """)
        try repo.write("demo/__init__.py", "")
        try repo.write("demo/core.py", """
        class Base:
            def greet(self) -> str:
                return "hi"

        class Child(Base):
            def greet(self) -> str:
                return super().greet() + "!"

        def make() -> Child:
            c = Child()
            return c.greet()
        """)
        _ = try git.run(["add", "."])
        _ = try git.run(["commit", "--quiet", "-m", "init"])
        return repo
    }

    func testResolveOffSkipsCleanly() throws {
        let repo = try makeRepo()
        let out = try TempDir()
        let db = try OrionDatabase(path: out.path("orion.db"))
        let result = try AnalysisPipeline(database: db).run(
            AnalysisInput(repoPath: repo.url, outputDirectory: out.url, resolve: false)
        )
        XCTAssertEqual(result.resolver, "none")
        try db.dbQueue.read { dbc in
            let calls = try Int.fetchOne(
                dbc, sql: "SELECT COUNT(*) FROM relationships WHERE relationship_type='calls'"
            )
            XCTAssertEqual(calls, 0)
            let scipDiag = try Int.fetchOne(
                dbc, sql: "SELECT COUNT(*) FROM diagnostics WHERE code='SCIP_UNAVAILABLE'"
            )
            XCTAssertEqual(scipDiag, 0)   // we chose not to resolve; not an error
            XCTAssertEqual(try AnalysisRunRecord.fetchOne(dbc)?.resolver, "none")
        }
    }

    func testScipEmitsCallsAndExtends() throws {
        try TestPaths.requireNpx()
        let repo = try makeRepo()
        let out = try TempDir()
        let db = try OrionDatabase(path: out.path("orion.db"))
        let result = try AnalysisPipeline(database: db).run(
            AnalysisInput(repoPath: repo.url, outputDirectory: out.url)
        )
        XCTAssertEqual(result.resolver, "scip-python@\(ScipIndexer.version)")

        try db.dbQueue.read { dbc in
            func edges(_ type: String) throws -> [(String, String)] {
                try Row.fetchAll(dbc, sql: """
                    SELECT s.anchor AS src, t.anchor AS tgt
                    FROM relationships r
                    JOIN symbols s ON s.id = r.source_symbol_id
                    JOIN symbols t ON t.id = r.target_symbol_id
                    WHERE r.relationship_type = ?
                    """, arguments: [type]).map { ($0["src"], $0["tgt"]) }
            }

            let extends = try edges("extends")
            XCTAssertTrue(extends.contains { $0 == ("demo/core.py::Child", "demo/core.py::Base") })

            let calls = try edges("calls")
            // Child.greet() -> super().greet() resolves to Base.greet
            XCTAssertTrue(calls.contains {
                $0.0 == "demo/core.py::Child.greet" && $0.1 == "demo/core.py::Base.greet"
            })

            let run = try XCTUnwrap(AnalysisRunRecord.fetchOne(dbc))
            let total = try Int.fetchOne(dbc, sql: "SELECT COUNT(*) FROM relationships") ?? -1
            XCTAssertEqual(run.relationshipCount, total)
        }
    }
}
