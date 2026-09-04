import XCTest
import GRDB
@testable import OrionCodeIntel

/// M2: the pipeline runs the parse pass, records `parse_ok` and `parse`-stage diagnostics.
final class ParsePipelineTests: XCTestCase {

    private func buildRepo(broken: Bool) throws -> TempDir {
        let tmp = try TempDir()
        let git = GitRunner(repoPath: tmp.url)
        _ = try git.run(["init", "--quiet", "-b", "main"])
        _ = try git.run(["config", "user.email", "t@e.com"])
        _ = try git.run(["config", "user.name", "T"])
        try tmp.write("pkg/__init__.py", "")
        try tmp.write("pkg/good.py", "def ok():\n    return 1\n")
        try tmp.write("pkg/also_good.py", "VALUE = 2\n")
        if broken {
            try tmp.write("pkg/bad.py", "def broken(:\n    return\n")
        }
        _ = try git.run(["add", "."])
        _ = try git.run(["commit", "--quiet", "-m", "init"])
        return tmp
    }

    func testCleanRepoHasNoParseErrors() throws {
        let repo = try buildRepo(broken: false)
        let out = try TempDir()
        let database = try OrionDatabase(path: out.path("orion.db"))
        let result = try AnalysisPipeline(database: database).run(
            AnalysisInput(repoPath: repo.url, outputDirectory: out.url, resolve: false)
        )
        XCTAssertEqual(result.parseErrorCount, 0)
        try database.dbQueue.read { db in
            let notOk = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM files WHERE parse_ok = 0")
            XCTAssertEqual(notOk, 0)
            XCTAssertNotNil(try AnalysisRunRecord.fetchOne(db)?.stageTimings["parse"])
        }
    }

    func testBrokenFileIsFlaggedAndDiagnosed() throws {
        let repo = try buildRepo(broken: true)
        let out = try TempDir()
        let database = try OrionDatabase(path: out.path("orion.db"))
        let result = try AnalysisPipeline(database: database).run(
            AnalysisInput(repoPath: repo.url, outputDirectory: out.url, resolve: false)
        )
        XCTAssertEqual(result.parseErrorCount, 1)

        try database.dbQueue.read { db in
            let bad = try FileRecord.filter(Column("path") == "pkg/bad.py").fetchOne(db)
            XCTAssertEqual(bad?.parseOk, false)
            let good = try FileRecord.filter(Column("path") == "pkg/good.py").fetchOne(db)
            XCTAssertEqual(good?.parseOk, true)

            let parseDiags = try DiagnosticRecord
                .filter(Column("stage") == "parse")
                .fetchAll(db)
            XCTAssertFalse(parseDiags.isEmpty)
            XCTAssertEqual(parseDiags.first?.fileId, bad?.id)
            XCTAssertNotNil(parseDiags.first?.startLine)
        }
    }
}
