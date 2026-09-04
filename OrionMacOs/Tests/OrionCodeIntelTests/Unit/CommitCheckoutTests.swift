import XCTest
import GRDB
@testable import OrionCodeIntel

/// M8: analyzing an explicit `--commit` checks it out, analyzes that tree, and restores the
/// previous ref.
final class CommitCheckoutTests: XCTestCase {

    func testAnalyzesRequestedCommitAndRestoresHead() throws {
        let repo = try TempDir()
        let git = GitRunner(repoPath: repo.url)
        _ = try git.run(["init", "--quiet", "-b", "main"])
        _ = try git.run(["config", "user.email", "t@e.com"])
        _ = try git.run(["config", "user.name", "T"])

        try repo.write("pkg/__init__.py", "")
        try repo.write("pkg/a.py", "def one(): return 1\n")
        _ = try git.run(["add", "."])
        _ = try git.run(["commit", "--quiet", "-m", "c1"])
        let first = try git.headCommit()

        try repo.write("pkg/b.py", "def two(): return 2\n")     // second file only in c2
        _ = try git.run(["add", "."])
        _ = try git.run(["commit", "--quiet", "-m", "c2"])
        let second = try git.headCommit()

        let out = try TempDir()
        let db = try OrionDatabase(path: out.path("orion.db"))
        let result = try AnalysisPipeline(database: db).run(
            AnalysisInput(
                repoPath: repo.url, explicitCommit: first, outputDirectory: out.url,
                resolve: false, export: false
            )
        )

        XCTAssertEqual(result.commitHash, first)
        try db.dbQueue.read { dbc in
            let paths = try Set(String.fetchAll(dbc, sql: "SELECT path FROM files"))
            XCTAssertTrue(paths.contains("pkg/a.py"))
            XCTAssertFalse(paths.contains("pkg/b.py"), "b.py did not exist at c1")
        }

        // HEAD restored to the branch tip
        XCTAssertEqual(try git.headCommit(), second)
        XCTAssertEqual(git.currentBranch(), "main")
    }
}
