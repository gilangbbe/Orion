import XCTest
import GRDB
@testable import OrionCodeIntel

/// M4 against vendored Starlette: the module dependency graph and external-dependency
/// classification.
final class StarletteImportsTests: XCTestCase {

    private static var db: OrionDatabase?
    private static var keepAlive: [TempDir] = []

    private func analyze() throws -> OrionDatabase {
        if let db = Self.db { return db }
        try TestPaths.requireStarlette()
        let out = try TempDir()
        Self.keepAlive.append(out)
        let db = try OrionDatabase(path: out.path("orion.db"))
        _ = try AnalysisPipeline(database: db).run(
            AnalysisInput(repoPath: TestPaths.vendoredStarlette, outputDirectory: out.url)
        )
        Self.db = db
        return db
    }

    func testModuleImportGraph() throws {
        let db = try analyze()
        try db.dbQueue.read { dbc in
            let targets = try Set(Row.fetchAll(dbc, sql: """
                SELECT t.qualified_name AS tgt
                FROM relationships r
                JOIN symbols s ON s.id = r.source_symbol_id
                JOIN symbols t ON t.id = r.target_symbol_id
                WHERE r.relationship_type = 'imports' AND s.qualified_name = 'starlette.applications'
                """).map { $0["tgt"] as String })

            for expected in ["starlette.middleware", "starlette.routing", "starlette.responses",
                             "starlette.types", "starlette.requests"] {
                XCTAssertTrue(targets.contains(expected), "applications should import \(expected)")
            }

            // imports edges only ever point at module/package symbols
            let bad = try Int.fetchOne(dbc, sql: """
                SELECT COUNT(*) FROM relationships r
                JOIN symbols t ON t.id = r.target_symbol_id
                WHERE r.relationship_type = 'imports' AND t.kind NOT IN ('module','package')
                """)
            XCTAssertEqual(bad, 0)

            let importsCount = try Int.fetchOne(
                dbc, sql: "SELECT COUNT(*) FROM relationships WHERE relationship_type='imports'"
            ) ?? 0
            XCTAssertGreaterThan(importsCount, 150)
        }
    }

    func testExternalDependencyClassification() throws {
        let db = try analyze()
        try db.dbQueue.read { dbc in
            let anyio = try XCTUnwrap(
                ExternalDependencyRecord.filter(Column("name") == "anyio").fetchOne(dbc)
            )
            XCTAssertEqual(anyio.source, "pyproject")
            XCTAssertEqual(anyio.versionSpec, ">=3.6.2,<5")
            XCTAssertGreaterThan(anyio.importCount, 0)

            let typing = try XCTUnwrap(
                ExternalDependencyRecord.filter(Column("name") == "typing").fetchOne(dbc)
            )
            XCTAssertTrue(typing.isStdlib)
            XCTAssertEqual(typing.source, "stdlib")

            // a depends_on edge references anyio
            let anyioEdges = try Int.fetchOne(dbc, sql: """
                SELECT COUNT(*) FROM relationships
                WHERE relationship_type='depends_on' AND external_dependency_id = ?
                """, arguments: [anyio.id])
            XCTAssertGreaterThan(anyioEdges ?? 0, 0)
        }
    }

    func testRunCountsMatch() throws {
        let db = try analyze()
        try db.dbQueue.read { dbc in
            let run = try XCTUnwrap(AnalysisRunRecord.fetchOne(dbc))
            let rel = try Int.fetchOne(dbc, sql: "SELECT COUNT(*) FROM relationships") ?? 0
            XCTAssertEqual(run.relationshipCount, rel)
            XCTAssertGreaterThan(rel, 300)
        }
    }
}
