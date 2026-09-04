import XCTest
import GRDB
@testable import OrionCodeIntel

/// M5 against vendored Starlette: the SCIP-derived call graph and inheritance edges.
final class StarletteResolutionTests: XCTestCase {

    private static var db: OrionDatabase?
    private static var keepAlive: [TempDir] = []

    private func analyze() throws -> OrionDatabase {
        if let db = Self.db { return db }
        try TestPaths.requireStarlette()
        try TestPaths.requireNpx()
        let out = try TempDir()
        Self.keepAlive.append(out)
        let db = try OrionDatabase(path: out.path("orion.db"))
        let result = try AnalysisPipeline(database: db).run(
            AnalysisInput(repoPath: TestPaths.vendoredStarlette, outputDirectory: out.url)
        )
        XCTAssertEqual(result.resolver, "scip-python@\(ScipIndexer.version)")
        Self.db = db
        return db
    }

    private func edgeExists(
        _ db: OrionDatabase, type: String, src: String, tgt: String
    ) throws -> Bool {
        try db.dbQueue.read { dbc in
            try Int.fetchOne(dbc, sql: """
                SELECT COUNT(*) FROM relationships r
                JOIN symbols s ON s.id = r.source_symbol_id
                JOIN symbols t ON t.id = r.target_symbol_id
                WHERE r.relationship_type = ? AND s.anchor = ? AND t.anchor = ?
                """, arguments: [type, src, tgt]) ?? 0
        } > 0
    }

    func testInheritanceEdges() throws {
        let db = try analyze()
        XCTAssertTrue(try edgeExists(
            db, type: "extends",
            src: "starlette/responses.py::JSONResponse", tgt: "starlette/responses.py::Response"
        ))
        for sub in ["HTMLResponse", "PlainTextResponse", "RedirectResponse", "StreamingResponse"] {
            XCTAssertTrue(try edgeExists(
                db, type: "extends",
                src: "starlette/responses.py::\(sub)", tgt: "starlette/responses.py::Response"
            ), "\(sub) should extend Response")
        }

        let extendsCount = try db.dbQueue.read { dbc in
            try Int.fetchOne(dbc, sql: "SELECT COUNT(*) FROM relationships WHERE relationship_type='extends'")
        }
        XCTAssertGreaterThan(extendsCount ?? 0, 50)
    }

    func testCallGraphEdges() throws {
        let db = try analyze()
        XCTAssertTrue(try edgeExists(
            db, type: "calls",
            src: "starlette/applications.py::Starlette.__call__",
            tgt: "starlette/applications.py::Starlette.build_middleware_stack"
        ))

        try db.dbQueue.read { dbc in
            let calls = try Int.fetchOne(
                dbc, sql: "SELECT COUNT(*) FROM relationships WHERE relationship_type='calls'"
            ) ?? 0
            XCTAssertGreaterThan(calls, 1000)

            // resolved call/extends edges always have both endpoints as real symbols
            let dangling = try Int.fetchOne(dbc, sql: """
                SELECT COUNT(*) FROM relationships
                WHERE relationship_type IN ('calls')
                  AND (source_symbol_id IS NULL OR target_symbol_id IS NULL)
                """) ?? -1
            XCTAssertEqual(dangling, 0)

            // no self-edges
            let selfEdges = try Int.fetchOne(dbc, sql: """
                SELECT COUNT(*) FROM relationships
                WHERE source_symbol_id = target_symbol_id AND source_symbol_id IS NOT NULL
                """) ?? -1
            XCTAssertEqual(selfEdges, 0)
        }
    }

    func testRunAccounting() throws {
        let db = try analyze()
        try db.dbQueue.read { dbc in
            let run = try XCTUnwrap(AnalysisRunRecord.fetchOne(dbc))
            let total = try Int.fetchOne(dbc, sql: "SELECT COUNT(*) FROM relationships") ?? -1
            XCTAssertEqual(run.relationshipCount, total)
            XCTAssertEqual(run.resolver, "scip-python@\(ScipIndexer.version)")
            XCTAssertNotNil(run.stageTimings["scip.index"])
            XCTAssertNotNil(run.stageTimings["resolve"])
        }
    }
}
