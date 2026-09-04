import Foundation

public enum GitError: Error, CustomStringConvertible {
    case notARepository(String)
    case commandFailed(command: String, status: Int32, stderr: String)
    case gitNotFound

    public var description: String {
        switch self {
        case .notARepository(let path): return "not a git repository: \(path)"
        case .commandFailed(let cmd, let status, let stderr):
            return "git \(cmd) failed (\(status)): \(stderr.trimmingCharacters(in: .whitespacesAndNewlines))"
        case .gitNotFound: return "git executable not found at /usr/bin/git"
        }
    }
}

/// Thin read-only wrapper around the `git` CLI. The only state-changing operation is
/// `checkout(_:)`, used by `--commit` and always paired with a restore.
public struct GitRunner {
    public let repoPath: URL
    private let gitURL = URL(fileURLWithPath: "/usr/bin/git")

    public init(repoPath: URL) { self.repoPath = repoPath }

    @discardableResult
    public func run(_ args: [String]) throws -> String {
        guard FileManager.default.isExecutableFile(atPath: gitURL.path) else {
            throw GitError.gitNotFound
        }
        let process = Process()
        process.executableURL = gitURL
        process.arguments = ["-C", repoPath.path] + args
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw GitError.commandFailed(
                command: args.joined(separator: " "),
                status: process.terminationStatus,
                stderr: String(decoding: errData, as: UTF8.self)
            )
        }
        return String(decoding: outData, as: UTF8.self)
    }

    public func isRepository() -> Bool {
        (try? run(["rev-parse", "--is-inside-work-tree"]))?
            .trimmingCharacters(in: .whitespacesAndNewlines) == "true"
    }

    public func headCommit() throws -> String {
        try run(["rev-parse", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Current branch name, or the empty string when the HEAD is detached.
    public func currentBranch() -> String {
        let value = (try? run(["symbolic-ref", "--quiet", "--short", "HEAD"])) ?? ""
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func topLevel() throws -> URL {
        let path = try run(["rev-parse", "--show-toplevel"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return URL(fileURLWithPath: path)
    }

    /// Tracked files as repo-relative POSIX paths (NUL-delimited, so paths with spaces are safe).
    public func trackedFiles() throws -> [String] {
        let raw = try run(["ls-files", "-z"])
        return raw.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
    }

    public func checkout(_ ref: String) throws {
        _ = try run(["checkout", "--quiet", ref])
    }
}
