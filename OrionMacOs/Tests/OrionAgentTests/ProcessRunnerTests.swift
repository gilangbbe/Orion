import XCTest

@testable import OrionAgent

/// Docs/12_phase3_mlx_agent.md Risk #4: Swift's `Process` has no built-in wall-clock timeout,
/// so `ProcessRunner`'s watchdog is hand-built and needs real verification, not just a
/// hopeful read of the code. Uses real system executables (`/bin/echo`, `/bin/sleep`, `/bin/sh`)
/// rather than the real `claude` CLI -- fast, deterministic, no network, safe for CI.
final class ProcessRunnerTests: XCTestCase {

    func testCapturesStdoutOnNormalCompletion() async throws {
        let result = try await ProcessRunner.run(
            executableURL: URL(fileURLWithPath: "/bin/echo"),
            arguments: ["hello from the child process"],
            timeout: 5
        )
        XCTAssertFalse(result.timedOut)
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(
            String(data: result.stdout, encoding: .utf8)?.trimmingCharacters(in: .newlines),
            "hello from the child process")
    }

    func testCapturesStderrSeparatelyFromStdout() async throws {
        let result = try await ProcessRunner.run(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "echo out-text; echo err-text 1>&2"],
            timeout: 5
        )
        XCTAssertEqual(String(data: result.stdout, encoding: .utf8)?.trimmingCharacters(in: .newlines), "out-text")
        XCTAssertEqual(String(data: result.stderr, encoding: .utf8)?.trimmingCharacters(in: .newlines), "err-text")
    }

    func testCapturesNonZeroExitCode() async throws {
        let result = try await ProcessRunner.run(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "exit 7"],
            timeout: 5
        )
        XCTAssertFalse(result.timedOut)
        XCTAssertEqual(result.exitCode, 7)
    }

    func testRespectsCurrentDirectory() async throws {
        let dir = try TempDir()
        let result = try await ProcessRunner.run(
            executableURL: URL(fileURLWithPath: "/bin/pwd"),
            arguments: [],
            currentDirectoryURL: dir.url,
            timeout: 5
        )
        let printedPath = String(data: result.stdout, encoding: .utf8)?.trimmingCharacters(in: .newlines)
        // /tmp is often a symlink to /private/tmp on macOS -- compare resolved paths.
        XCTAssertEqual(
            printedPath.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path },
            dir.url.resolvingSymlinksInPath().path)
    }

    /// The real risk this whole type exists to cover: a process that runs long past its
    /// deadline must be killed and reported as timed out, not hang the caller forever.
    func testTimeoutTerminatesLongRunningProcessAndReportsTimedOut() async throws {
        let start = ContinuousClock.now
        let result = try await ProcessRunner.run(
            executableURL: URL(fileURLWithPath: "/bin/sleep"),
            arguments: ["30"],
            timeout: 1
        )
        let elapsed = start.duration(to: .now)

        XCTAssertTrue(result.timedOut)
        XCTAssertLessThan(
            elapsed, .seconds(5),
            "the watchdog must fire at the configured timeout, not wait out the full sleep")
    }

    func testProcessThatFinishesJustBeforeTimeoutIsNotFlaggedTimedOut() async throws {
        let result = try await ProcessRunner.run(
            executableURL: URL(fileURLWithPath: "/bin/sleep"),
            arguments: ["0.1"],
            timeout: 5
        )
        XCTAssertFalse(result.timedOut)
        XCTAssertEqual(result.exitCode, 0)
    }

    func testLaunchFailureThrowsRatherThanHanging() async {
        await XCTAssertThrowsErrorAsync(
            try await ProcessRunner.run(
                executableURL: URL(fileURLWithPath: "/no/such/executable/anywhere"),
                arguments: [],
                timeout: 5
            )
        )
    }
}

/// XCTest has no built-in async throwing-error assertion.
func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    file: StaticString = #filePath, line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("expected an error to be thrown", file: file, line: line)
    } catch {
        // expected
    }
}
