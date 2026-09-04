import XCTest
import GRDB
@testable import OrionCodeIntel

/// Ingestion against the pinned vendored Starlette checkout. Skips when it is absent
/// (the vendor dir is gitignored). Symbol/relationship assertions arrive in later milestones.
final class StarletteIngestionTests: XCTestCase {

    func testIngestsVendoredStarlette() throws {
        try TestPaths.requireStarlette()

        let out = try TempDir()
        let database = try OrionDatabase(path: out.path("orion.db"))
        let result = try AnalysisPipeline(database: database).run(
            AnalysisInput(repoPath: TestPaths.vendoredStarlette, outputDirectory: out.url)
        )

        XCTAssertEqual(result.commitHash, TestPaths.starlettePinnedCommit)
        XCTAssertGreaterThan(result.pythonFileCount, 60)
        XCTAssertGreaterThan(result.fileCount, result.pythonFileCount)

        try database.dbQueue.read { db in
            func file(_ path: String) throws -> FileRecord? {
                try FileRecord.filter(Column("path") == path).fetchOne(db)
            }

            let app = try file("starlette/applications.py")
            XCTAssertEqual(app?.modulePath, "starlette.applications")
            XCTAssertEqual(app?.language, "python")
            XCTAssertEqual(app?.isPackageInit, false)

            let mwInit = try file("starlette/middleware/__init__.py")
            XCTAssertEqual(mwInit?.modulePath, "starlette.middleware")
            XCTAssertEqual(mwInit?.isPackageInit, true)

            let testFile = try file("tests/test_applications.py")
            XCTAssertEqual(testFile?.isTest, true)
            XCTAssertEqual(testFile?.modulePath, "tests.test_applications")

            // every python file resolved a module path
            let unresolved = try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM files WHERE language='python' AND module_path IS NULL"
            )
            XCTAssertEqual(unresolved, 0)

            // anyio declared in pyproject
            let anyio = try ExternalDependencyRecord.filter(Column("name") == "anyio").fetchOne(db)
            XCTAssertEqual(anyio?.source, "pyproject")
            XCTAssertEqual(anyio?.versionSpec, ">=3.6.2,<5")
        }

        // M2: every Python file parses cleanly under tree-sitter.
        XCTAssertEqual(result.parseErrorCount, 0)
        try database.dbQueue.read { db in
            let notOk = try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM files WHERE language='python' AND parse_ok = 0"
            )
            XCTAssertEqual(notOk, 0)
        }

        let report = try StatsReporter.build(database: database, commitHash: nil)
        XCTAssertEqual(report.status, "succeeded")
        XCTAssertEqual(report.parseOkCount, report.fileCount)
        XCTAssertNotNil(report.stageTimingsMs["parse"])
    }
}
