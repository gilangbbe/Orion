import XCTest

@testable import Orion

/// A scripted `RepositoryCloning` conformer -- lets these tests drive every
/// `RepositorySession` transition without a real network call, mirroring how
/// `ClaudeCodeInvestigatorTests` (Docs/12 M3) substitutes a stand-in for the real `claude` CLI.
private struct FakeCloner: RepositoryCloning {
    var result: Result<URL, Error>

    func clone(url: URL) async throws -> URL {
        try result.get()
    }
}

private struct FakeCloneError: Error, CustomStringConvertible {
    let description: String
}

final class RepositorySessionTests: XCTestCase {
    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("RepositorySessionTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testInitialStateIsIdle() {
        let session = RepositorySession()
        XCTAssertEqual(session.state, .idle)
        XCTAssertNil(session.resolvedRepoRoot)
    }

    func testOpenValidLocalPathReachesAnalyzing() async throws {
        let directory = try makeTempDirectory()
        let session = RepositorySession()

        await session.open(.localPath(directory))

        XCTAssertEqual(session.state, .analyzing)
        XCTAssertEqual(session.resolvedRepoRoot, directory)
    }

    func testOpenMissingLocalPathFails() async {
        let missing = URL(fileURLWithPath: "/tmp/definitely-does-not-exist-\(UUID().uuidString)")
        let session = RepositorySession()

        await session.open(.localPath(missing))

        guard case .failed = session.state else {
            return XCTFail("expected .failed, got \(session.state)")
        }
        XCTAssertNil(session.resolvedRepoRoot)
    }

    func testOpenLocalPathThatIsAFileNotADirectoryFails() async throws {
        let directory = try makeTempDirectory()
        let filePath = directory.appendingPathComponent("not-a-directory.txt")
        try Data("hello".utf8).write(to: filePath)
        let session = RepositorySession()

        await session.open(.localPath(filePath))

        guard case .failed = session.state else {
            return XCTFail("expected .failed, got \(session.state)")
        }
    }

    func testOpenValidGitHubURLReachesAnalyzingViaCloner() async throws {
        let cloned = try makeTempDirectory()
        let cloner = FakeCloner(result: .success(cloned))
        let session = RepositorySession(cloner: cloner)

        await session.open(.gitHubURL(URL(string: "https://github.com/owner/repo")!))

        XCTAssertEqual(session.state, .analyzing)
        XCTAssertEqual(session.resolvedRepoRoot, cloned)
    }

    func testOpenGitHubURLSurfacesClonerValidationFailure() async {
        // Stands in for a malformed URL -- RepositoryClonerTests covers the real validation
        // logic; this test only confirms the session surfaces whatever the cloner throws.
        let cloner = FakeCloner(
            result: .failure(RepositoryClonerError.invalidURL("not-a-url")))
        let session = RepositorySession(cloner: cloner)

        await session.open(.gitHubURL(URL(string: "https://example.com")!))

        guard case .failed(let message) = session.state else {
            return XCTFail("expected .failed, got \(session.state)")
        }
        XCTAssertTrue(message.contains("not-a-url"))
    }

    func testOpenGitHubURLSurfacesCloneFailure() async {
        let cloner = FakeCloner(
            result: .failure(
                RepositoryClonerError.cloneFailed(exitCode: 128, stderr: "repository not found")))
        let session = RepositorySession(cloner: cloner)

        await session.open(.gitHubURL(URL(string: "https://github.com/owner/missing")!))

        guard case .failed(let message) = session.state else {
            return XCTFail("expected .failed, got \(session.state)")
        }
        XCTAssertTrue(message.contains("repository not found"))
    }

    func testAnalysisSucceededReachesReady() async throws {
        let directory = try makeTempDirectory()
        let session = RepositorySession()
        await session.open(.localPath(directory))

        let summary = RepositorySummary(
            repoRoot: directory,
            outputDirectory: RepositorySession.outputDirectory(forRepoRoot: directory),
            languages: ["python"], fileCount: 3, symbolCount: 12, relationshipCount: 5,
            resolver: "none", parseErrorCount: 0, diagnosticCount: 0, totalDurationMs: 42)
        session.analysisSucceeded(summary)

        XCTAssertEqual(session.state, .ready(summary))
    }

    func testAnalysisFailedReachesFailed() async throws {
        let directory = try makeTempDirectory()
        let session = RepositorySession()
        await session.open(.localPath(directory))

        session.analysisFailed("pipeline exploded")

        XCTAssertEqual(session.state, .failed("pipeline exploded"))
    }

    func testResetReturnsToIdle() async throws {
        let directory = try makeTempDirectory()
        let session = RepositorySession()
        await session.open(.localPath(directory))

        session.reset()

        XCTAssertEqual(session.state, .idle)
        XCTAssertNil(session.resolvedRepoRoot)
    }

    func testOutputDirectoryMatchesOrionIndexConvention() {
        let repoRoot = URL(fileURLWithPath: "/tmp/some-repo")
        XCTAssertEqual(
            RepositorySession.outputDirectory(forRepoRoot: repoRoot).path,
            "/tmp/some-repo/.orion")
    }
}
