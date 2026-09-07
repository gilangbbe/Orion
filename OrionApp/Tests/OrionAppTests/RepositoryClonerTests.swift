import XCTest

@testable import Orion

/// Every test here uses a stand-in `git` shell script instead of the real binary -- no network
/// call, matching how `ClaudeCodeInvestigatorTests` (Docs/12 M3) mocks the `claude` CLI with a
/// script rather than calling the real thing.
final class RepositoryClonerTests: XCTestCase {
    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("RepositoryClonerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Writes an executable shell script standing in for `git`. `body` receives the script's
    /// own path so it can (optionally) record its argv/cwd for the test to inspect afterward.
    private func makeStubGit(_ script: String) throws -> URL {
        let directory = try makeTempDirectory()
        let scriptURL = directory.appendingPathComponent("git")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        return scriptURL
    }

    private let sampleURL = URL(string: "https://github.com/owner/repo")!

    func testCloneRejectsNonHTTPSScheme() async {
        let cloner = RepositoryCloner(gitExecutableURL: URL(fileURLWithPath: "/usr/bin/git"))
        do {
            _ = try await cloner.clone(url: URL(string: "ssh://github.com/owner/repo")!)
            XCTFail("expected invalidURL")
        } catch RepositoryClonerError.invalidURL {
            // expected
        } catch {
            XCTFail("expected invalidURL, got \(error)")
        }
    }

    func testCloneRejectsURLWithNoHost() async {
        let cloner = RepositoryCloner(gitExecutableURL: URL(fileURLWithPath: "/usr/bin/git"))
        do {
            _ = try await cloner.clone(url: URL(string: "https:///owner/repo")!)
            XCTFail("expected invalidURL")
        } catch RepositoryClonerError.invalidURL {
            // expected
        } catch {
            XCTFail("expected invalidURL, got \(error)")
        }
    }

    func testCloneThrowsGitNotFoundWhenExecutableMissing() async {
        let missing = URL(fileURLWithPath: "/tmp/no-such-git-\(UUID().uuidString)")
        let destinationDir = try! makeTempDirectory()
        let cloner = RepositoryCloner(
            gitExecutableURL: missing,
            destinationDirectory: { _ in destinationDir.appendingPathComponent("repo") })

        do {
            _ = try await cloner.clone(url: sampleURL)
            XCTFail("expected gitNotFound")
        } catch RepositoryClonerError.gitNotFound {
            // expected
        } catch {
            XCTFail("expected gitNotFound, got \(error)")
        }
    }

    func testCloneInvokesGitWithExpectedArgumentsAndReturnsDestination() async throws {
        let argsFile = try makeTempDirectory().appendingPathComponent("args.txt")
        let stubGit = try makeStubGit(
            """
            #!/bin/sh
            echo "$@" > "\(argsFile.path)"
            mkdir -p "$5/.git"
            exit 0
            """)
        let destinationParent = try makeTempDirectory()
        let destination = destinationParent.appendingPathComponent("cloned-repo")
        let cloner = RepositoryCloner(
            gitExecutableURL: stubGit, destinationDirectory: { _ in destination })

        let result = try await cloner.clone(url: sampleURL)

        XCTAssertEqual(result, destination)
        let recordedArgs = try String(contentsOf: argsFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(recordedArgs, "clone --depth 1 \(sampleURL.absoluteString) \(destination.path)")
    }

    func testCloneReusesExistingCheckoutWithoutInvokingGit() async throws {
        // A stub that would fail loudly if actually invoked -- proves clone() short-circuits.
        let stubGit = try makeStubGit(
            """
            #!/bin/sh
            echo "git should not have been invoked" >&2
            exit 1
            """)
        let destination = try makeTempDirectory().appendingPathComponent("already-cloned")
        try FileManager.default.createDirectory(
            at: destination.appendingPathComponent(".git"), withIntermediateDirectories: true)
        let cloner = RepositoryCloner(
            gitExecutableURL: stubGit, destinationDirectory: { _ in destination })

        let result = try await cloner.clone(url: sampleURL)

        XCTAssertEqual(result, destination)
    }

    func testCloneThrowsOnNonZeroExit() async throws {
        let stubGit = try makeStubGit(
            """
            #!/bin/sh
            echo "fatal: repository not found" >&2
            exit 128
            """)
        let destination = try makeTempDirectory().appendingPathComponent("repo")
        let cloner = RepositoryCloner(
            gitExecutableURL: stubGit, destinationDirectory: { _ in destination })

        do {
            _ = try await cloner.clone(url: sampleURL)
            XCTFail("expected cloneFailed")
        } catch RepositoryClonerError.cloneFailed(let exitCode, let stderr) {
            XCTAssertEqual(exitCode, 128)
            XCTAssertTrue(stderr.contains("repository not found"))
        } catch {
            XCTFail("expected cloneFailed, got \(error)")
        }
    }

    func testCloneReportsTimeout() async throws {
        let stubGit = try makeStubGit(
            """
            #!/bin/sh
            sleep 5
            exit 0
            """)
        let destination = try makeTempDirectory().appendingPathComponent("repo")
        let cloner = RepositoryCloner(
            gitExecutableURL: stubGit, timeout: 1,
            destinationDirectory: { _ in destination })

        do {
            _ = try await cloner.clone(url: sampleURL)
            XCTFail("expected timedOut")
        } catch RepositoryClonerError.timedOut {
            // expected
        } catch {
            XCTFail("expected timedOut, got \(error)")
        }
    }
}
