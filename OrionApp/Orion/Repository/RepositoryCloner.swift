import Foundation
import OrionAgent

/// How `RepositorySession` turns a GitHub URL into a local checkout -- kept behind a protocol
/// so tests can substitute a fake instead of touching the network (mirrors
/// `OrionAgent`'s own `TurnGenerating` seam for the same reason: orchestration is testable
/// without the real, slow, external thing).
protocol RepositoryCloning: Sendable {
    func clone(url: URL) async throws -> URL
}

enum RepositoryClonerError: Error, CustomStringConvertible, Equatable {
    case invalidURL(String)
    case gitNotFound
    case cloneFailed(exitCode: Int32, stderr: String)
    case timedOut

    var description: String {
        switch self {
        case .invalidURL(let value): return "not a valid repository URL: \(value)"
        case .gitNotFound: return "git executable not found"
        case .cloneFailed(let code, let stderr):
            return "git clone failed (\(code)): \(stderr.trimmingCharacters(in: .whitespacesAndNewlines))"
        case .timedOut: return "git clone timed out"
        }
    }
}

/// Public-HTTPS-only `git clone` wrapper (Docs/13_phase4_architecture_ui.md Decision 2's v1
/// scope -- no PAT/SSH auth, no private repos). Reuses `OrionAgent.ProcessRunner`'s
/// watchdog-timeout subprocess primitive directly rather than re-implementing the same
/// deadlock-avoiding pipe-draining/timeout-racing logic Docs/12 M3 already built and verified
/// live against a real `/bin/sleep`.
///
/// `gitExecutableURL` and `destinationDirectory` are injectable so tests can point at a stand-in
/// script instead of the real `git` binary and a real network call -- the same posture
/// `ClaudeCodeInvestigatorTests` (Docs/12 M3) uses for the `claude` CLI.
struct RepositoryCloner: RepositoryCloning {
    private let gitExecutableURL: URL
    private let timeout: TimeInterval
    private let destinationDirectory: @Sendable (URL) -> URL

    init(
        gitExecutableURL: URL = URL(fileURLWithPath: "/usr/bin/git"),
        timeout: TimeInterval = 120,
        destinationDirectory: @escaping @Sendable (URL) -> URL = { url in
            AppPaths.clonedRepositoryDirectory(for: url)
        }
    ) {
        self.gitExecutableURL = gitExecutableURL
        self.timeout = timeout
        self.destinationDirectory = destinationDirectory
    }

    func clone(url: URL) async throws -> URL {
        guard url.scheme?.lowercased() == "https", let host = url.host, !host.isEmpty else {
            throw RepositoryClonerError.invalidURL(url.absoluteString)
        }
        guard FileManager.default.isExecutableFile(atPath: gitExecutableURL.path) else {
            throw RepositoryClonerError.gitNotFound
        }

        let destination = destinationDirectory(url)
        if isExistingCheckout(destination) {
            return destination  // already cloned -- skip a redundant network round trip
        }
        // A stale/partial clone from a previously-interrupted attempt shouldn't block a retry;
        // `git clone` itself refuses to clone into a non-empty directory.
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)

        let result = try await ProcessRunner.run(
            executableURL: gitExecutableURL,
            arguments: ["clone", "--depth", "1", url.absoluteString, destination.path],
            timeout: timeout
        )
        if result.timedOut {
            throw RepositoryClonerError.timedOut
        }
        guard result.exitCode == 0 else {
            throw RepositoryClonerError.cloneFailed(
                exitCode: result.exitCode,
                stderr: String(decoding: result.stderr, as: UTF8.self))
        }
        return destination
    }

    private func isExistingCheckout(_ path: URL) -> Bool {
        FileManager.default.fileExists(atPath: path.appendingPathComponent(".git").path)
    }
}
