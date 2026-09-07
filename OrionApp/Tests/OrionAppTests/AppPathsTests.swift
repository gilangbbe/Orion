import XCTest

@testable import Orion

final class AppPathsTests: XCTestCase {
    func testClonedRepositoryDirectoryIsStableForTheSameURL() {
        let url = URL(string: "https://github.com/owner/repo")!
        XCTAssertEqual(
            AppPaths.clonedRepositoryDirectory(for: url),
            AppPaths.clonedRepositoryDirectory(for: url))
    }

    func testClonedRepositoryDirectoryDiffersForDifferentURLs() {
        let a = URL(string: "https://github.com/owner/repo-a")!
        let b = URL(string: "https://github.com/owner/repo-b")!
        XCTAssertNotEqual(
            AppPaths.clonedRepositoryDirectory(for: a), AppPaths.clonedRepositoryDirectory(for: b))
    }

    func testClonedRepositoryDirectoryNestsUnderTheReposDirectory() {
        let url = URL(string: "https://github.com/owner/repo")!
        let path = AppPaths.clonedRepositoryDirectory(for: url)
        XCTAssertTrue(
            path.path.hasPrefix(AppPaths.clonedRepositoriesDirectory.path),
            "\(path.path) should nest under \(AppPaths.clonedRepositoriesDirectory.path)")
    }
}
