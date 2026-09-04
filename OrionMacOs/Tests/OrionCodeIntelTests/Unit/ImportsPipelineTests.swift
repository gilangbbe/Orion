import XCTest
import GRDB
@testable import OrionCodeIntel

/// M4: the pipeline emits `imports` / `depends_on` edges and mints `external_dependencies`.
final class ImportsPipelineTests: XCTestCase {

    private func analyze() throws -> OrionDatabase {
        let repo = try TempDir()
        let git = GitRunner(repoPath: repo.url)
        _ = try git.run(["init", "--quiet", "-b", "main"])
        _ = try git.run(["config", "user.email", "t@e.com"])
        _ = try git.run(["config", "user.name", "T"])

        try repo.write("pyproject.toml", """
        [project]
        name = "demo"
        dependencies = ["anyio>=3.6.2"]
        """)
        try repo.write("demo/__init__.py", "")
        try repo.write("demo/a.py", """
        import os
        import anyio
        import weirdlib
        from demo import b
        from . import c
        from demo.sub.deep import thing
        """)
        try repo.write("demo/b.py", "VALUE = 1\n")
        try repo.write("demo/c.py", "VALUE = 2\n")
        try repo.write("demo/sub/__init__.py", "")
        try repo.write("demo/sub/deep.py", "def thing(): pass\n")
        _ = try git.run(["add", "."])
        _ = try git.run(["commit", "--quiet", "-m", "init"])

        let out = try TempDir()
        keepAlive.append(out)
        keepAlive.append(repo)
        let db = try OrionDatabase(path: out.path("orion.db"))
        _ = try AnalysisPipeline(database: db).run(
            AnalysisInput(repoPath: repo.url, outputDirectory: out.url, resolve: false)
        )
        return db
    }

    private var keepAlive: [TempDir] = []

    func testInRepoImportEdges() throws {
        let db = try analyze()
        try db.dbQueue.read { dbc in
            func importsTargets(of moduleQN: String) throws -> Set<String> {
                let rows = try Row.fetchAll(dbc, sql: """
                    SELECT t.qualified_name AS tgt
                    FROM relationships r
                    JOIN symbols s ON s.id = r.source_symbol_id
                    JOIN symbols t ON t.id = r.target_symbol_id
                    WHERE r.relationship_type = 'imports' AND s.qualified_name = ?
                    """, arguments: [moduleQN])
                return Set(rows.map { $0["tgt"] })
            }
            let targets = try importsTargets(of: "demo.a")
            XCTAssertTrue(targets.contains("demo.b"))
            XCTAssertTrue(targets.contains("demo.c"))          // relative `from . import c`
            XCTAssertTrue(targets.contains("demo.sub.deep"))   // `from demo.sub.deep import thing`

            // every imports edge targets a module/package symbol
            let badTargets = try Int.fetchOne(dbc, sql: """
                SELECT COUNT(*) FROM relationships r
                JOIN symbols t ON t.id = r.target_symbol_id
                WHERE r.relationship_type = 'imports' AND t.kind NOT IN ('module','package')
                """)
            XCTAssertEqual(badTargets, 0)
        }
    }

    func testExternalDependencyEdges() throws {
        let db = try analyze()
        try db.dbQueue.read { dbc in
            func dep(_ name: String) throws -> ExternalDependencyRecord? {
                try ExternalDependencyRecord.filter(Column("name") == name).fetchOne(dbc)
            }
            let os = try XCTUnwrap(dep("os"))
            XCTAssertEqual(os.source, "stdlib")
            XCTAssertTrue(os.isStdlib)
            XCTAssertEqual(os.importCount, 1)

            let anyio = try XCTUnwrap(dep("anyio"))
            XCTAssertEqual(anyio.source, "pyproject")       // declared, not re-minted
            XCTAssertEqual(anyio.versionSpec, ">=3.6.2")
            XCTAssertEqual(anyio.importCount, 1)

            let weird = try XCTUnwrap(dep("weirdlib"))
            XCTAssertEqual(weird.source, "inferred")
            XCTAssertFalse(weird.isStdlib)

            let dependsOn = try Int.fetchOne(dbc, sql: """
                SELECT COUNT(*) FROM relationships r
                JOIN symbols s ON s.id = r.source_symbol_id
                WHERE r.relationship_type = 'depends_on' AND s.qualified_name = 'demo.a'
                """)
            XCTAssertEqual(dependsOn, 3)   // os, anyio, weirdlib
        }
    }

    func testRunRelationshipCount() throws {
        let db = try analyze()
        try db.dbQueue.read { dbc in
            let run = try XCTUnwrap(try AnalysisRunRecord.fetchOne(dbc))
            let actual = try Int.fetchOne(dbc, sql: "SELECT COUNT(*) FROM relationships")
            XCTAssertEqual(run.relationshipCount, actual)
            XCTAssertGreaterThan(run.relationshipCount, 0)
        }
    }
}
