import Foundation
import OrionCore

/// The local (Qwen3 on Core AI) drafting path — a single plain-chat generation. Docs/17 §6.2: band
/// 1–2 questions are drafted locally. Wraps a closure rather than a model directly so the CLI
/// owns model loading and this stays trivially testable; `TeachingQuestionGenerator` does the
/// tolerant JSON extraction on whatever string comes back.
public struct LocalTeachingDrafter: TeachingQuestionDrafting {
    public let source: TeachingQuestionSource = .local
    private let generate: @Sendable (_ prompt: String) async throws -> String

    public init(generate: @escaping @Sendable (_ prompt: String) async throws -> String) {
        self.generate = generate
    }

    public func draft(prompt: String, band: Int) async throws -> String {
        try await generate(prompt)
    }

    /// The short system instruction the local model runs under — keeps it in "emit one JSON
    /// object" mode.
    public static let systemInstruction = """
        You author grounded teaching questions for a code-comprehension tutor. You always reply \
        with exactly one JSON object and nothing else — no prose, no markdown fences, no \
        commentary before or after.
        """
}

// The Claude drafter runs the `claude` CLI as a subprocess: Mac only (Docs/19 M1).
#if os(macOS)
public enum ClaudeTeachingDrafterError: Error, CustomStringConvertible {
    case schemaEncodingFailed
    case timedOut(Double)
    case noCandidate(stderrTail: String)

    public var description: String {
        switch self {
        case .schemaEncodingFailed: return "failed to encode TeachingSchema.cliJSONSchema() as JSON"
        case .timedOut(let ms): return "claude CLI timed out after \(Int(ms)) ms"
        case .noCandidate(let tail): return "claude CLI produced no usable JSON candidate. \(tail)"
        }
    }
}

/// The delegated (Claude Code CLI) drafting path — Docs/17 §6.2: band 3 (multi-hop / change-
/// impact) questions. Ports `ClaudeCodeInvestigator`'s exact headless read-only contract
/// (`-p --output-format json`, `--tools Read,Grep,Glob`, `--add-dir <export>`, `bypassPermissions`,
/// `--max-budget-usd`, `--json-schema` without `$schema`) — same flags, same reasoning — just with
/// `TeachingSchema.cliJSONSchema()` and no session-continuity dimension (a generation is always a
/// one-off).
public struct ClaudeTeachingDrafter: TeachingQuestionDrafting {
    public let source: TeachingQuestionSource = .claudeCode
    public let repoRoot: URL
    public let exportDir: URL
    public var model: String
    public var maxBudgetUsd: Double
    public var timeoutSeconds: Double
    public var claudeBinary: String

    public init(
        repoRoot: URL, exportDir: URL, model: String = "claude-sonnet-5",
        maxBudgetUsd: Double = 0.50, timeoutSeconds: Double = 400, claudeBinary: String = "claude"
    ) {
        self.repoRoot = repoRoot
        self.exportDir = exportDir
        self.model = model
        self.maxBudgetUsd = maxBudgetUsd
        self.timeoutSeconds = timeoutSeconds
        self.claudeBinary = claudeBinary
    }

    func buildArguments(prompt: String) throws -> [String] {
        let schemaData = try JSONSerialization.data(withJSONObject: TeachingSchema.cliJSONSchema())
        guard let schemaString = String(data: schemaData, encoding: .utf8) else {
            throw ClaudeTeachingDrafterError.schemaEncodingFailed
        }
        return [
            claudeBinary, "-p",
            "--output-format", "json",
            "--model", model,
            "--tools", "Read,Grep,Glob",
            "--permission-mode", "bypassPermissions",
            "--max-budget-usd", String(maxBudgetUsd),
            "--add-dir", exportDir.path,
            "--json-schema", schemaString,
            "--no-session-persistence",
            prompt,
        ]
    }

    public func draft(prompt: String, band: Int) async throws -> String {
        let result = try await ProcessRunner.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/env"),
            arguments: try buildArguments(prompt: prompt),
            currentDirectoryURL: repoRoot,
            timeout: timeoutSeconds)

        if result.timedOut {
            throw ClaudeTeachingDrafterError.timedOut(Double(timeoutSeconds) * 1000)
        }
        guard let wrapper = (try? JSONSerialization.jsonObject(with: result.stdout)) as? [String: Any]
        else {
            // Not a wrapper at all — hand the raw stdout to the generator's tolerant extractor.
            return String(decoding: result.stdout, as: UTF8.self)
        }
        if let structured = wrapper["structured_output"] as? [String: Any],
           let data = try? JSONSerialization.data(withJSONObject: structured) {
            return String(decoding: data, as: UTF8.self)
        }
        if let text = wrapper["result"] as? String, text.contains("{") { return text }
        // No candidate — surface the CLI's own account of why (budget exhausted, schema-conformance
        // failure, …) instead of a bare "no output", the same gap Phase 5 M5 fixed for
        // `ClaudeCodeInvestigator` (`errors`/`subtype` in the wrapper).
        let reason: String
        if let errors = wrapper["errors"] as? [String], !errors.isEmpty {
            reason = errors.joined(separator: "; ")
        } else if let subtype = wrapper["subtype"] as? String {
            reason = subtype
        } else if let text = wrapper["result"] as? String, !text.isEmpty {
            reason = "result had no JSON object: \(text.prefix(200))"
        } else {
            reason = String(decoding: result.stderr.suffix(400), as: UTF8.self)
        }
        throw ClaudeTeachingDrafterError.noCandidate(stderrTail: reason)
    }
}
#endif
