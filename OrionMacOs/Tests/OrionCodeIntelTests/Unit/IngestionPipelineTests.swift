import XCTest
import GRDB
@testable import OrionCodeIntel

/// Full ingestion pipeline over a synthetic repo (no network, no vendored corpus).
final class IngestionPipelineTests: XCTestCase {

    private func buildRepo() throws -> TempDir {
        let tmp = try TempDir()
        let git = GitRunner(repoPath: tmp.url)
        _ = try git.run(["init", "--quiet", "-b", "main"])
        _ = try git.run(["config", "user.email", "t@e.com"])
        _ = try git.run(["config", "user.name", "T"])

        try tmp.write("pyproject.toml", """
        [project]
        name = "demo"
        dependencies = ["anyio>=3.6.2,<5", "click"]
        [project.optional-dependencies]
        test = ["pytest>=8"]
        """)
        try tmp.write("demo/__init__.py", "")
        try tmp.write("demo/core.py", "def hello():\n    return 1\n")
        try tmp.write("demo/util/__init__.py", "")
        try tmp.write("demo/util/text.py", "VALUE = 'x'\n")
        try tmp.write("tests/test_core.py", "from demo.core import hello\n\ndef test_hello():\n    assert hello() == 1\n")
        try tmp.write("README.md", "# demo\n")

        _ = try git.run(["add", "."])
        _ = try git.run(["commit", "--quiet", "-m", "init"])
        return tmp
    }

    func testPipelinePopulatesIngestionTables() throws {
        let repo = try buildRepo()
        let out = try TempDir()
        let database = try OrionDatabase(path: out.path("orion.db"))
        let result = try AnalysisPipeline(database: database).run(
            AnalysisInput(repoPath: repo.url, outputDirectory: out.url, resolve: false)
        )

        XCTAssertEqual(result.commitHash.count, 40)
        XCTAssertEqual(result.fileCount, 7)
        XCTAssertEqual(result.pythonFileCount, 5)
        XCTAssertEqual(result.parseErrorCount, 0)

        try database.dbQueue.read { db in
            // repository row
            let repoRow = try RepositoryRecord.fetchOne(db)
            XCTAssertEqual(repoRow?.analysisStatus, "succeeded")
            XCTAssertEqual(repoRow?.languages, ["python"])

            // run row
            let run = try AnalysisRunRecord.fetchOne(db)
            XCTAssertEqual(run?.status, "succeeded")
            XCTAssertEqual(run?.resolver, "none")
            XCTAssertEqual(run?.grammarVersions["python"], PythonLanguageSupport.grammarVersion)
            XCTAssertNotNil(run?.finishedAt)
            XCTAssertFalse(run?.stageTimings.isEmpty ?? true)

            // files
            let core = try FileRecord.filter(Column("path") == "demo/core.py").fetchOne(db)
            XCTAssertEqual(core?.modulePath, "demo.core")
            XCTAssertEqual(core?.language, "python")
            XCTAssertEqual(core?.isPackageInit, false)
            XCTAssertEqual(core?.isTest, false)

            let pkgInit = try FileRecord.filter(Column("path") == "demo/util/__init__.py").fetchOne(db)
            XCTAssertEqual(pkgInit?.modulePath, "demo.util")
            XCTAssertEqual(pkgInit?.isPackageInit, true)

            let test = try FileRecord.filter(Column("path") == "tests/test_core.py").fetchOne(db)
            XCTAssertEqual(test?.isTest, true)

            let readme = try FileRecord.filter(Column("path") == "README.md").fetchOne(db)
            XCTAssertNil(readme?.language)
            XCTAssertNil(readme?.modulePath)

            // external dependencies (runtime + optional groups)
            let deps = try ExternalDependencyRecord.fetchAll(db)
            let byName = Dictionary(uniqueKeysWithValues: deps.map { ($0.name, $0) })
            XCTAssertEqual(byName["anyio"]?.versionSpec, ">=3.6.2,<5")
            XCTAssertEqual(byName["anyio"]?.source, "pyproject")
            XCTAssertNotNil(byName["click"])
            XCTAssertEqual(byName["pytest"]?.versionSpec, ">=8")
            XCTAssertNil(byName["demo"])   // self-reference dropped
        }
    }

    func testCleanReplacesPriorRun() throws {
        let repo = try buildRepo()
        let out = try TempDir()
        let dbPath = out.path("orion.db")

        _ = try AnalysisPipeline(database: try OrionDatabase(path: dbPath)).run(
            AnalysisInput(repoPath: repo.url, outputDirectory: out.url, resolve: false)
        )
        _ = try AnalysisPipeline(database: try OrionDatabase(path: dbPath)).run(
            AnalysisInput(repoPath: repo.url, outputDirectory: out.url, clean: true)
        )

        let runCount = try OrionDatabase(path: dbPath).dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM analysis_runs") ?? -1
        }
        XCTAssertEqual(runCount, 1, "--clean should leave exactly one run")
    }

    func testStatsReportMatches() throws {
        let repo = try buildRepo()
        let out = try TempDir()
        let database = try OrionDatabase(path: out.path("orion.db"))
        _ = try AnalysisPipeline(database: database).run(
            AnalysisInput(repoPath: repo.url, outputDirectory: out.url, resolve: false)
        )

        let report = try StatsReporter.build(database: database, commitHash: nil)
        XCTAssertEqual(report.fileCount, 7)
        XCTAssertEqual(report.pythonFileCount, 5)
        XCTAssertEqual(report.filesByLanguage["python"], 5)
        XCTAssertEqual(report.parseOkCount, 7)
        XCTAssertGreaterThan(report.symbolCount, 0)   // M3+
        XCTAssertEqual(report.status, "succeeded")
    }
}
