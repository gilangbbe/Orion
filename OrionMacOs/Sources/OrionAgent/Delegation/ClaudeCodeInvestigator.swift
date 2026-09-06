import Foundation
import OrionCodeIntel

/// One headless Claude Code CLI investigation over a repository checkout, answering a single
/// question — Docs/12_phase3_mlx_agent.md "Claude delegation (L3)". Ports the exact contract
/// Phase 2's Python `investigate.py` already validated live against real `claude` 2.1.260
/// output, rather than re-deriving it: same flags, same reasoning, same read-only posture.
///
/// Unlike Phase 2 (Python CLI bridge -> file -> separate Swift `ingest-semantic` process), this
/// runs in the same Swift process as `SemanticImporter.ingestAnswer` — `investigate(question:)`
/// hands back the candidate JSON directly as `Data`, no temp file, no cross-process handoff.
public struct ClaudeCodeInvestigator {
    public let repoRoot: URL
    public let exportDir: URL
    public var model: String
    public var maxBudgetUsd: Double
    public var timeoutSeconds: Double
    public var claudeBinary: String

    public init(
        repoRoot: URL, exportDir: URL,
        model: String = "claude-sonnet-5",
        maxBudgetUsd: Double = 2.00,
        timeoutSeconds: Double = 900,
        claudeBinary: String = "claude"
    ) {
        self.repoRoot = repoRoot
        self.exportDir = exportDir
        self.model = model
        self.maxBudgetUsd = maxBudgetUsd
        self.timeoutSeconds = timeoutSeconds
        self.claudeBinary = claudeBinary
    }

    public func buildPrompt(question: String) -> String {
        """
        You are investigating a Python repository to answer one specific developer question, \
        as the delegated deep-reasoning step of Orion's agent (Docs/06_claude_code_integration.md).

        You have read-only tools (Read, Grep, Glob) over the repository at the current working \
        directory. A directory at \(exportDir.path) holds a deterministically-extracted Code \
        Graph: `code_graph.json` is a compact skeleton (modules, classes, import matrix, \
        entrypoints, test map); `symbols.jsonl` lists every symbol with its exact `anchor`; \
        `relationships.jsonl` lists every resolved import/call/inheritance edge. Read \
        `code_graph.json` first -- it is your map of the repository, already fact-checked; you \
        do not need to re-derive it from scratch, only use it to decide where to look with \
        Read/Grep for the reasoning a deterministic tool cannot do.

        Question: \(question)

        Rules:
        1. Every claim's `evidence` entry MUST be an anchor copied verbatim from \
           `symbols.jsonl`'s `anchor` field ("<path>::<Dotted.Name>" form, or a bare path for a \
           module symbol). Do not invent an anchor, guess its spelling, paraphrase it, or cite \
           a line number instead -- an anchor that does not match exactly will be rejected and \
           the claim discarded, however plausible the underlying observation was.
        2. `claim_type` must be INTERPRETATION (a semantic reading of what evidenced code does) \
           or INFERENCE (a conclusion reached by combining multiple facts). Never claim FACT -- \
           that tier is reserved for the deterministic extraction that already produced \
           code_graph.json.
        3. If something seems relevant to the question but you cannot ground it in a specific \
           symbol, put it in `uncertainties` as plain text instead of inventing evidence for \
           it. An honest uncertainty is a correct, valued outcome.
        4. Answer the question directly and specifically -- don't pad with generic commentary.

        Return your final answer as a single JSON object with exactly this shape (schema_version \
        must be exactly "\(AgentAnswerSchema.currentVersion)"):
        \(AgentAnswerSchema.promptHint)
        """
    }

    /// Options first, prompt last: `-p`/`--print` is a boolean flag (not `-p <value>`), so
    /// ordering the positional prompt after every option avoids any ambiguity about what it
    /// binds to -- same ordering Phase 2's `build_command()` used.
    public func buildArguments(prompt: String) throws -> [String] {
        let schemaData = try JSONSerialization.data(withJSONObject: AgentAnswerSchema.cliJSONSchema())
        guard let schemaString = String(data: schemaData, encoding: .utf8) else {
            throw ClaudeCodeInvestigatorError.schemaEncodingFailed
        }
        return [
            claudeBinary,
            "-p",
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

    public func investigate(question: String) async throws -> ClaudeCodeInvestigationResult {
        let prompt = buildPrompt(question: question)
        let arguments = try buildArguments(prompt: prompt)

        let start = ContinuousClock.now
        let result = try await ProcessRunner.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/env"),
            arguments: arguments,
            currentDirectoryURL: repoRoot,
            timeout: timeoutSeconds
        )
        let elapsed = start.duration(to: .now)
        let elapsedMs =
            Double(elapsed.components.seconds) * 1000
            + Double(elapsed.components.attoseconds) / 1e15

        if result.timedOut {
            return ClaudeCodeInvestigationResult(
                rawWrapper: result.stdout, candidateData: nil, sessionId: nil, modelUsed: model,
                numTurns: nil, totalCostUsd: nil, durationMs: elapsedMs, timedOut: true,
                isError: false, stderrTail: Self.tail(result.stderr)
            )
        }

        guard let wrapper = (try? JSONSerialization.jsonObject(with: result.stdout)) as? [String: Any],
            !wrapper.isEmpty
        else {
            return ClaudeCodeInvestigationResult(
                rawWrapper: result.stdout, candidateData: nil, sessionId: nil, modelUsed: model,
                numTurns: nil, totalCostUsd: nil, durationMs: elapsedMs, timedOut: false,
                isError: true, stderrTail: Self.tail(result.stderr)
            )
        }

        // `structured_output` is already a `--json-schema`-conformant object when present --
        // confirmed against a real Phase 2 run (M1). Prefer it; fall back to tolerantly
        // extracting `result` text otherwise. `SemanticImporter.ingestAnswer` still decodes and
        // validates whichever one this returns unconditionally -- a flag asking for structured
        // output, or a wrapper field named as if it were, is never trusted on its own.
        let candidateData: Data?
        if let structured = wrapper["structured_output"] as? [String: Any] {
            candidateData = try? JSONSerialization.data(withJSONObject: structured)
        } else if let resultText = wrapper["result"] as? String {
            candidateData = Self.extractJSONObject(resultText)
        } else {
            candidateData = nil
        }

        return ClaudeCodeInvestigationResult(
            rawWrapper: result.stdout,
            candidateData: candidateData,
            sessionId: wrapper["session_id"] as? String,
            modelUsed: Self.dominantModel(wrapper) ?? model,
            numTurns: wrapper["num_turns"] as? Int,
            totalCostUsd: wrapper["total_cost_usd"] as? Double,
            durationMs: (wrapper["duration_ms"] as? Double) ?? elapsedMs,
            timedOut: false,
            isError: (wrapper["is_error"] as? Bool) ?? false,
            errorMessage: Self.errorMessage(wrapper),
            stderrTail: Self.tail(result.stderr)
        )
    }

    /// The wrapper's own account of what went wrong, when it has one -- confirmed live (M5): a
    /// budget-exhausted run (`--max-budget-usd` reached before a final answer) sets
    /// `is_error: true` with an empty `result`/`structured_output` *and* an `errors: [...]`
    /// array naming the reason, plus `subtype: "error_max_budget_usd"`. Without surfacing this,
    /// the caller only ever sees a generic "produced no output" -- indistinguishable from a
    /// crash, a bad schema, or the CLI simply not being installed.
    private static func errorMessage(_ wrapper: [String: Any]) -> String? {
        if let errors = wrapper["errors"] as? [String], !errors.isEmpty {
            return errors.joined(separator: "; ")
        }
        return wrapper["subtype"] as? String
    }

    /// Tolerant extraction: first `{` to last `}` -- same posture as Phase 2's `extract_json`
    /// and Phase 3's own `ActionLoop.extractJSONObject` for the same reason (never assume a
    /// model's raw text is exactly, only, the JSON it was asked for).
    private static func extractJSONObject(_ text: String) -> Data? {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end
        else { return nil }
        return text[start...end].data(using: .utf8)
    }

    /// The wrapper has no top-level "model" field (confirmed against a real Phase 2 run) --
    /// only a per-model `modelUsage` cost breakdown. Picks whichever was actually billed the
    /// most, same as Phase 2's `_dominant_model`.
    private static func dominantModel(_ wrapper: [String: Any]) -> String? {
        guard let usage = wrapper["modelUsage"] as? [String: Any], !usage.isEmpty else { return nil }
        return usage.max { a, b in
            let costA = ((a.value as? [String: Any])?["costUSD"] as? Double) ?? 0
            let costB = ((b.value as? [String: Any])?["costUSD"] as? Double) ?? 0
            return costA < costB
        }?.key
    }

    private static func tail(_ data: Data, limit: Int = 2000) -> String {
        let s = String(data: data, encoding: .utf8) ?? ""
        return String(s.suffix(limit))
    }
}

public enum ClaudeCodeInvestigatorError: Error, CustomStringConvertible {
    case schemaEncodingFailed
    public var description: String {
        "failed to encode AgentAnswerSchema.cliJSONSchema() as JSON"
    }
}

/// The raw result of one `ClaudeCodeInvestigator.investigate(question:)` call — deliberately
/// carries no "outcome" verdict of its own. `investigations.outcome` is always
/// `SemanticImporter`'s own computed verdict from what actually survives validation, never
/// copied from this type's (or Claude's) self-report (Docs/03 §5).
public struct ClaudeCodeInvestigationResult: Sendable {
    public let rawWrapper: Data
    public let candidateData: Data?
    public let sessionId: String?
    public let modelUsed: String?
    public let numTurns: Int?
    public let totalCostUsd: Double?
    public let durationMs: Double
    public let timedOut: Bool
    public let isError: Bool
    /// The wrapper's own `errors`/`subtype` account of what went wrong, when there is one --
    /// `nil` on success, on a timeout (no wrapper was ever parsed), and on a totally empty/
    /// unparseable stdout (nothing to extract a reason from).
    public let errorMessage: String?
    public let stderrTail: String

    public init(
        rawWrapper: Data, candidateData: Data?, sessionId: String?, modelUsed: String?,
        numTurns: Int?, totalCostUsd: Double?, durationMs: Double, timedOut: Bool, isError: Bool,
        errorMessage: String? = nil, stderrTail: String
    ) {
        self.rawWrapper = rawWrapper
        self.candidateData = candidateData
        self.sessionId = sessionId
        self.modelUsed = modelUsed
        self.numTurns = numTurns
        self.totalCostUsd = totalCostUsd
        self.durationMs = durationMs
        self.timedOut = timedOut
        self.isError = isError
        self.errorMessage = errorMessage
        self.stderrTail = stderrTail
    }

    /// Maps directly onto `OrionCodeIntel.InvestigationMeta`, the small sidecar shape
    /// `SemanticImporter.ingestAnswer` actually consumes.
    public var investigationMeta: InvestigationMeta {
        InvestigationMeta(
            modelUsed: modelUsed, sessionId: sessionId, numTurns: numTurns,
            totalCostUsd: totalCostUsd, durationMs: durationMs,
            toolsUsed: ["Read", "Grep", "Glob"]
        )
    }
}
