import XCTest
@testable import OrionCodeIntel

final class GitRunnerTests: XCTestCase {

    private func makeRepo() throws -> (TempDir, GitRunner) {
        let tmp = try TempDir()
        let git = GitRunner(repoPath: tmp.url)
        _ = try git.run(["init", "--quiet", "-b", "main"])
        _ = try git.run(["config", "user.email", "test@example.com"])
        _ = try git.run(["config", "user.name", "Test"])
        return (tmp, git)
    }

    func testHeadCommitAndTrackedFiles() throws {
        let (tmp, git) = try makeRepo()
        try tmp.write("a.py", "x = 1\n")
        try tmp.write("sub/b.py", "y = 2\n")
        _ = try git.run(["add", "."])
        _ = try git.run(["commit", "--quiet", "-m", "init"])

        XCTAssertTrue(git.isRepository())
        XCTAssertEqual(git.currentBranch(), "main")
        XCTAssertEqual(try git.headCommit().count, 40)
        XCTAssertEqual(Set(try git.trackedFiles()), ["a.py", "sub/b.py"])
    }

    func testUntrackedFileNotListed() throws {
        let (tmp, git) = try makeRepo()
        try tmp.write("tracked.py", "x = 1\n")
        _ = try git.run(["add", "tracked.py"])
        _ = try git.run(["commit", "--quiet", "-m", "init"])
        try tmp.write("untracked.py", "y = 2\n")
        XCTAssertEqual(try git.trackedFiles(), ["tracked.py"])
    }

    func testCheckoutAndRestore() throws {
        let (tmp, git) = try makeRepo()
        try tmp.write("a.py", "v = 1\n")
        _ = try git.run(["add", "."])
        _ = try git.run(["commit", "--quiet", "-m", "c1"])
        let first = try git.headCommit()
        try tmp.write("a.py", "v = 2\n")
        _ = try git.run(["add", "."])
        _ = try git.run(["commit", "--quiet", "-m", "c2"])
        let second = try git.headCommit()

        try git.checkout(first)
        XCTAssertEqual(try git.headCommit(), first)
        try git.checkout("main")
        XCTAssertEqual(try git.headCommit(), second)
    }

    func testNonRepoDirectory() throws {
        let tmp = try TempDir()
        XCTAssertFalse(GitRunner(repoPath: tmp.url).isRepository())
    }
}
