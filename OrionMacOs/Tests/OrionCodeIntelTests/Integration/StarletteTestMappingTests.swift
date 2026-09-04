import XCTest
import GRDB
@testable import OrionCodeIntel

/// M6 against vendored Starlette: `tested_by` edges from test symbols to production symbols.
final class StarletteTestMappingTests: XCTestCase {

    private static var db: OrionDatabase?
    private static var keepAlive: [TempDir] = []

    private func analyze() throws -> OrionDatabase {
        if let db = Self.db { return db }
        try TestPaths.requireStarlette()
        try TestPaths.requireNpx()
        let out = try TempDir()
        Self.keepAlive.append(out)
        let db = try OrionDatabase(path: out.path("orion.db"))
        _ = try AnalysisPipeline(database: db).run(
            AnalysisInput(repoPath: TestPaths.vendoredStarlette, outputDirectory: out.url)
        )
        Self.db = db
        return db
    }

    func testTestedByEdges() throws {
        let db = try analyze()
        try db.dbQueue.read { dbc in
            let total = try Int.fetchOne(
                dbc, sql: "SELECT COUNT(*) FROM relationships WHERE relationship_type='tested_by'"
            ) ?? 0
            XCTAssertGreaterThan(total, 200)

            // test_applications.py exercises Starlette
            let toApplications = try Int.fetchOne(dbc, sql: """
                SELECT COUNT(*) FROM relationships r
                JOIN symbols s ON s.id = r.source_symbol_id
                JOIN symbols t ON t.id = r.target_symbol_id
                WHERE r.relationship_type = 'tested_by'
                  AND s.anchor LIKE 'tests/test_applications.py::%'
                  AND t.anchor LIKE 'starlette/applications.py::%'
                """) ?? 0
            XCTAssertGreaterThan(toApplications, 5)

            // name-matched test file -> production module produces at least one high-tier edge
            let highs = try Int.fetchOne(dbc, sql: """
                SELECT COUNT(*) FROM relationships
                WHERE relationship_type='tested_by' AND confidence_tier='high'
                """) ?? 0
            XCTAssertGreaterThan(highs, 20)
        }
    }

    func testEveryEdgeGoesTestToProduction() throws {
        let db = try analyze()
        try db.dbQueue.read { dbc in
            let bad = try Int.fetchOne(dbc, sql: """
                SELECT COUNT(*) FROM relationships r
                JOIN files sf ON sf.id = (SELECT file_id FROM symbols WHERE id = r.source_symbol_id)
                JOIN files tf ON tf.id = (SELECT file_id FROM symbols WHERE id = r.target_symbol_id)
                WHERE r.relationship_type = 'tested_by'
                  AND (sf.is_test = 0 OR tf.is_test = 1)
                """) ?? -1
            XCTAssertEqual(bad, 0)
        }
    }
}
