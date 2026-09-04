import Foundation

/// Runs `scip-python` (Pyright-based) over a repo checkout and returns the path to the
/// emitted SCIP index — or a reason it could not run, so the pipeline degrades gracefully
/// (resolved open question #2).
public struct ScipIndexer {
    /// Pinned `scip-python` release.
    public static let version = "0.6.6"

    public enum Result {
        case success(indexPath: URL, resolver: String)
        case unavailable(reason: String)
    }

    public let repoRoot: URL
    public let workDir: URL
    public let projectName: String
    public let projectVersion: String
    public let timeout: TimeInterval

    public init(
        repoRoot: URL, workDir: URL, projectName: String, projectVersion: String,
        timeout: TimeInterval = 900
    ) {
        self.repoRoot = repoRoot
        self.workDir = workDir
        self.projectName = projectName
        self.projectVersion = projectVersion
        self.timeout = timeout
    }

    public func run() -> Result {
        let fm = FileManager.default
        guard let npx = which("npx") else {
            return .unavailable(reason: "npx not found on PATH")
        }

        // Empty environment file → scip-python skips the (slow, sometimes ENOBUFS-prone)
        // `pip3 show` enumeration of the ambient Python install. We only emit in-repo edges,
        // so third-party type resolution is not needed.
        let envFile = workDir.appendingPathComponent("scip-env.json")
        let indexPath = workDir.appendingPathComponent("index.scip")
        try? "[]".write(to: envFile, atomically: true, encoding: .utf8)
        try? fm.removeItem(at: indexPath)

        let process = Process()
        process.executableURL = npx
        process.arguments = [
            "--yes", "@sourcegraph/scip-python@\(Self.version)",
            "index", ".",
            "--project-name", projectName,
            "--project-version", projectVersion,
            "--environment", envFile.path,
            "--output", indexPath.path,
            "--quiet",
        ]
        process.currentDirectoryURL = repoRoot
        var env = ProcessInfo.processInfo.environment
        env["NODE_OPTIONS"] = "--max-old-space-size=8192"
        process.environment = env
        let sink = Pipe()
        process.standardOutput = sink
        process.standardError = sink

        do {
            try process.run()
        } catch {
            return .unavailable(reason: "failed to launch npx: \(error)")
        }

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning {
            if Date() > deadline {
                process.terminate()
                return .unavailable(reason: "scip-python timed out after \(Int(timeout))s")
            }
            Thread.sleep(forTimeInterval: 0.2)
        }
        _ = sink.fileHandleForReading.readDataToEndOfFile()

        guard process.terminationStatus == 0 else {
            return .unavailable(reason: "scip-python exited \(process.terminationStatus)")
        }
        guard fm.fileExists(atPath: indexPath.path),
              (try? indexPath.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0 > 64
        else {
            return .unavailable(reason: "scip-python produced no usable index")
        }
        return .success(indexPath: indexPath, resolver: "scip-python@\(Self.version)")
    }

    // MARK: helpers

    private func which(_ tool: String) -> URL? {
        let paths = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":").map(String.init)
            + ["/usr/local/bin", "/opt/homebrew/bin", "/usr/bin"]
        for dir in paths {
            let candidate = URL(fileURLWithPath: dir).appendingPathComponent(tool)
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        return nil
    }
}
