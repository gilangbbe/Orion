import Foundation

/// The result of running one subprocess to completion or timeout.
public struct ProcessRunResult: Sendable {
    public let stdout: Data
    public let stderr: Data
    public let exitCode: Int32
    public let timedOut: Bool
}

public enum ProcessRunnerError: Error, CustomStringConvertible {
    case launchFailed(String)
    public var description: String {
        switch self {
        case .launchFailed(let message): return "failed to launch process: \(message)"
        }
    }
}

/// Runs one subprocess with an explicit wall-clock timeout — Docs/12_phase3_mlx_agent.md Risk
/// #4: unlike Python's one-line `subprocess.run(timeout:)`, Swift's `Process` has no built-in
/// deadline, so this is hand-built rather than assumed to exist. Extracted as a standalone,
/// executable-agnostic primitive (not baked into `ClaudeCodeInvestigator` directly) so the
/// timeout/output-capture logic is unit-testable with `/bin/sleep`/`/bin/echo` — fast,
/// deterministic, no real `claude` CLI needed for that coverage.
public enum ProcessRunner {

    /// - Parameters:
    ///   - executableURL: the binary to run directly (no shell) -- e.g. `/usr/bin/env` with the
    ///     real command as the first argument, so callers don't need the target binary's full
    ///     path resolved ahead of time.
    ///   - timeout: wall-clock deadline. On expiry, the process is sent `terminate()` and the
    ///     result reports `timedOut: true` with whatever output was captured up to that point.
    public static func run(
        executableURL: URL,
        arguments: [String],
        currentDirectoryURL: URL? = nil,
        timeout: TimeInterval
    ) async throws -> ProcessRunResult {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        if let currentDirectoryURL {
            process.currentDirectoryURL = currentDirectoryURL
        }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        // `readabilityHandler` drains each pipe as data arrives, rather than reading after
        // `waitUntilExit()` -- the classic deadlock trap: if the child writes enough to fill
        // the pipe buffer before anyone reads it, and nobody reads until after the process
        // exits, both sides block forever (the child waiting to write, us waiting to exit).
        let stdoutCollector = OutputCollector()
        let stderrCollector = OutputCollector()
        stdoutCollector.attach(to: stdoutPipe.fileHandleForReading)
        stderrCollector.attach(to: stderrPipe.fileHandleForReading)

        let outcome: (timedOut: Bool, launchError: Error?) = await withCheckedContinuation { continuation in
            let resumeGuard = ResumeGuard()

            process.terminationHandler = { _ in
                resumeGuard.resumeOnce(with: (false, nil), continuation: continuation)
            }

            do {
                try process.run()
            } catch {
                resumeGuard.resumeOnce(with: (false, error), continuation: continuation)
                return
            }

            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                if process.isRunning {
                    process.terminate()
                }
                resumeGuard.resumeOnce(with: (true, nil), continuation: continuation)
            }
        }

        if let launchError = outcome.launchError {
            throw ProcessRunnerError.launchFailed("\(launchError)")
        }

        let stdout = stdoutCollector.finish(stdoutPipe.fileHandleForReading)
        let stderr = stderrCollector.finish(stderrPipe.fileHandleForReading)

        return ProcessRunResult(
            stdout: stdout, stderr: stderr,
            exitCode: outcome.timedOut ? -1 : process.terminationStatus,
            timedOut: outcome.timedOut
        )
    }

    /// Thread-safe, append-only buffer fed by a pipe's `readabilityHandler`.
    private final class OutputCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var buffer = Data()

        func attach(to handle: FileHandle) {
            handle.readabilityHandler = { [weak self] fh in
                let chunk = fh.availableData
                guard !chunk.isEmpty else { return }
                self?.append(chunk)
            }
        }

        private func append(_ chunk: Data) {
            lock.lock()
            defer { lock.unlock() }
            buffer.append(chunk)
        }

        func finish(_ handle: FileHandle) -> Data {
            handle.readabilityHandler = nil
            lock.lock()
            defer { lock.unlock() }
            return buffer
        }
    }

    /// Exactly one of `terminationHandler` (process exited) and the timeout's `asyncAfter`
    /// block can win; whichever runs second must be a no-op, or `CheckedContinuation` traps on
    /// a double-resume. A process that exits abnormally right as the timeout also fires is the
    /// scenario this guards.
    private final class ResumeGuard: @unchecked Sendable {
        private let lock = NSLock()
        private var didResume = false

        func resumeOnce<T>(
            with value: T, continuation: CheckedContinuation<T, Never>
        ) {
            lock.lock()
            defer { lock.unlock() }
            guard !didResume else { return }
            didResume = true
            continuation.resume(returning: value)
        }
    }
}
