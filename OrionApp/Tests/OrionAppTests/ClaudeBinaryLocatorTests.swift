import XCTest

@testable import Orion

/// Regression tests for a real bug: a GUI-launched app's minimal environment can't find `claude`
/// by bare name even when it's genuinely installed, because it doesn't inherit an interactive
/// shell's `PATH`. `loginShellLookup` is injected so these tests never actually shell out to a
/// real `/bin/zsh`.
final class ClaudeBinaryLocatorTests: XCTestCase {
    private func makeExecutableStub() throws -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudeBinaryLocatorTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("claude").path
        try Data("#!/bin/sh\necho ok\n".utf8).write(to: URL(fileURLWithPath: path))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        return path
    }

    func testResolveReturnsFirstExistingCandidateWithoutFallingBackToLoginShell() async throws {
        let candidatePath = try makeExecutableStub()

        let resolved = await ClaudeBinaryLocator.resolve(
            candidates: ["/nonexistent/claude", candidatePath],
            loginShellLookup: {
                XCTFail("should not fall back to the login shell when a candidate exists")
                return nil
            })

        XCTAssertEqual(resolved, candidatePath)
    }

    func testResolveSkipsNonExecutableCandidatesInOrder() async throws {
        let realStub = try makeExecutableStub()

        let resolved = await ClaudeBinaryLocator.resolve(
            candidates: ["/nonexistent/claude-a", "/nonexistent/claude-b", realStub],
            loginShellLookup: { nil })

        XCTAssertEqual(resolved, realStub)
    }

    func testResolveFallsBackToLoginShellWhenNoCandidateExists() async {
        let resolved = await ClaudeBinaryLocator.resolve(
            candidates: ["/nonexistent/claude"],
            loginShellLookup: { "/custom/install/path/claude" })

        XCTAssertEqual(resolved, "/custom/install/path/claude")
    }

    func testResolveReturnsBareNameWhenNothingIsFoundAnywhere() async {
        let resolved = await ClaudeBinaryLocator.resolve(
            candidates: ["/nonexistent/claude"],
            loginShellLookup: { nil })

        XCTAssertEqual(resolved, "claude")
    }

    func testResolveTreatsAnEmptyLoginShellResultAsNotFound() async {
        let resolved = await ClaudeBinaryLocator.resolve(
            candidates: ["/nonexistent/claude"],
            loginShellLookup: { "" })

        XCTAssertEqual(resolved, "claude")
    }
}
