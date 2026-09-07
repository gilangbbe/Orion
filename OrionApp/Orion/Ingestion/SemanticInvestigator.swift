import Foundation
import OrionAgent

/// The Phase 2 whole-repo structured-output contract (`schema_version` "phase2.v1"), ported
/// field-for-field from `Agent Feasibility Study/harness/orion_eval/semantic/schema.py`'s
/// `SEMANTIC_SCHEMA`/`SCHEMA_HINT` -- kept here, app-local, rather than added to
/// `OrionCodeIntel` (which already decodes this exact shape via `SemanticFindings`) since this
/// is only the *prompt-construction* half, never previously ported to Swift (Phase 3 built a
/// parallel contract for single-question answers, `AgentAnswerSchema`, not this one).
enum SemanticSchemaContract {
    static let schemaVersion = "phase2.v1"

    /// For the `claude --json-schema` CLI flag -- deliberately no `$schema` key, mirroring
    /// `cli_json_schema()`'s own documented reason (the CLI's offline validator doesn't have the
    /// 2020-12 meta-schema registered and rejects the request outright if `$schema` names it
    /// explicitly).
    static func cliJSONSchema() -> [String: Any] {
        [
            "type": "object",
            "required": ["schema_version", "components", "component_relationships", "claims", "uncertainties"],
            "additionalProperties": false,
            "properties": [
                "schema_version": ["const": schemaVersion],
                "components": [
                    "type": "array",
                    "items": [
                        "type": "object",
                        "required": ["name", "members"],
                        "additionalProperties": false,
                        "properties": [
                            "name": ["type": "string", "minLength": 1],
                            "description": ["type": ["string", "null"]],
                            "architectural_role": ["type": ["string", "null"]],
                            "members": [
                                "type": "array",
                                "items": ["type": "string", "minLength": 1],
                                "minItems": 1,
                            ],
                        ],
                    ],
                ],
                "component_relationships": [
                    "type": "array",
                    "items": [
                        "type": "object",
                        "required": ["source", "target", "type"],
                        "additionalProperties": false,
                        "properties": [
                            "source": ["type": "string", "minLength": 1],
                            "target": ["type": "string", "minLength": 1],
                            "type": ["type": "string", "minLength": 1],
                        ],
                    ],
                ],
                "claims": [
                    "type": "array",
                    "items": [
                        "type": "object",
                        "required": ["claim_type", "statement", "evidence", "confidence"],
                        "additionalProperties": false,
                        "properties": [
                            // FACT and CONTRADICTED are deliberately absent -- Claude never
                            // self-tags either (Docs/11: FACT is Phase 1's, CONTRADICTED is a
                            // Swift-side verdict).
                            "claim_type": ["enum": ["INTERPRETATION", "INFERENCE", "UNKNOWN"]],
                            "statement": ["type": "string", "minLength": 1],
                            "evidence": [
                                "type": "array", "items": ["type": "string", "minLength": 1],
                            ],
                            "confidence": ["enum": ["high", "medium", "low", "unresolved"]],
                        ],
                    ],
                ],
                "uncertainties": ["type": "array", "items": ["type": "string", "minLength": 1]],
            ],
        ]
    }

    /// Given verbatim to the model as its target shape -- byte-identical content to
    /// `investigate.py`'s `SCHEMA_HINT` (formatting differs only because that's `json.dumps`
    /// output and this is a hand-written literal; the model reads either as an example, not
    /// machine-parsed).
    static let promptHint = """
        {
          "schema_version": "\(schemaVersion)",
          "components": [{
            "name": "<short component name>",
            "description": "<what it does, one or two sentences>",
            "architectural_role": "<e.g. core | supporting>",
            "members": ["<path>::<Dotted.Name>", "..."]
          }],
          "component_relationships": [
            {"source": "<component name>", "target": "<component name>", "type": "depends_on"}
          ],
          "claims": [{
            "claim_type": "INTERPRETATION | INFERENCE | UNKNOWN",
            "statement": "<a specific, evidence-backed claim>",
            "evidence": ["<path>::<Dotted.Name>", "..."],
            "confidence": "high | medium | low | unresolved"
          }],
          "uncertainties": ["<something architecturally important you could not ground in evidence>"]
        }
        """
}

/// One headless Claude Code CLI investigation that groups a whole repository's symbols into
/// semantic components -- the "Build Architecture Model" action
/// (Docs/13_phase4_architecture_ui.md M3). Ports the exact contract Phase 2's Python
/// `investigate.py` already validated live against real `claude` output, the same way
/// `OrionAgent.ClaudeCodeInvestigator` (Docs/12 M3) ported it for the single-question case --
/// kept as a separate, app-local type rather than added to `OrionAgent` itself, since this phase
/// makes no further changes to Phases 1-3's libraries beyond M2's one additive hook.
struct SemanticInvestigator {
    let repoRoot: URL
    let exportDir: URL
    var model: String
    var maxBudgetUsd: Double
    var timeoutSeconds: Double
    var claudeBinary: String

    init(
        repoRoot: URL, exportDir: URL, model: String = "claude-sonnet-5",
        maxBudgetUsd: Double = 2.00, timeoutSeconds: Double = 900, claudeBinary: String = "claude"
    ) {
        self.repoRoot = repoRoot
        self.exportDir = exportDir
        self.model = model
        self.maxBudgetUsd = maxBudgetUsd
        self.timeoutSeconds = timeoutSeconds
        self.claudeBinary = claudeBinary
    }

    /// Ported verbatim (content, not formatting) from `investigate.py`'s `SYSTEM_PROMPT_TEMPLATE`.
    func buildPrompt() -> String {
        """
        You are investigating a Python repository to reconstruct its semantic architecture for \
        a tool called Orion.

        You have read-only tools (Read, Grep, Glob) over the repository at the current working \
        directory. A directory at \(exportDir.path) holds a deterministically-extracted Code \
        Graph: `code_graph.json` is a compact skeleton (modules, classes, import matrix, \
        entrypoints, test map); `symbols.jsonl` lists every symbol with its exact `anchor`; \
        `relationships.jsonl` lists every resolved import/call/inheritance edge. Read \
        `code_graph.json` first -- it is your map of the repository, already fact-checked; you \
        do not need to re-derive it from scratch, only use it to decide where to look with \
        Read/Grep for the semantic judgment a deterministic tool cannot make.

        Task: group the repository's symbols into a small number of coherent architectural \
        components (for example "Routing", "Middleware", "Requests/Responses" -- names specific \
        to this repository, not a generic template), each with a short description, an \
        architectural role, and the member symbols that belong to it. Then identify the most \
        important relationships between components, and a handful of specific, evidence-backed \
        claims about how the system behaves.

        Rules:
        1. Every `members` entry and every claim's `evidence` entry MUST be an anchor copied \
           verbatim from `symbols.jsonl`'s `anchor` field ("<path>::<Dotted.Name>" form, or a \
           bare path for a module symbol). Do not invent an anchor, guess its spelling, \
           paraphrase it, or cite a line number instead -- an anchor that does not match exactly \
           will be rejected and the finding discarded, however plausible the underlying \
           observation was.
        2. `claim_type` must be INTERPRETATION (a semantic reading of what evidenced code does) \
           or INFERENCE (a conclusion reached by combining multiple facts). Never claim FACT -- \
           that tier is reserved for the deterministic extraction that already produced \
           code_graph.json.
        3. If something seems architecturally important but you cannot ground it in a specific \
           symbol, put it in `uncertainties` as plain text instead of inventing evidence for it. \
           An honest uncertainty is a correct, valued outcome.
        4. Prefer a small number of well-evidenced components over many thin or overlapping ones.

        Return your final answer as a single JSON object with exactly this shape (schema_version \
        must be exactly "\(SemanticSchemaContract.schemaVersion)"):
        \(SemanticSchemaContract.promptHint)
        """
    }

    /// Options first, prompt last -- same ordering `investigate.py`'s `build_command()` uses,
    /// for the same reason: `-p`/`--print` is a boolean flag, not `-p <value>`.
    func buildArguments(prompt: String) throws -> [String] {
        let schemaData = try JSONSerialization.data(
            withJSONObject: SemanticSchemaContract.cliJSONSchema())
        guard let schemaString = String(data: schemaData, encoding: .utf8) else {
            throw SemanticInvestigatorError.schemaEncodingFailed
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

    func investigate() async throws -> SemanticInvestigationResult {
        let prompt = buildPrompt()
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
            return SemanticInvestigationResult(
                candidateData: nil, sessionId: nil, modelUsed: model, numTurns: nil,
                totalCostUsd: nil, durationMs: elapsedMs, timedOut: true, isError: false,
                errorMessage: "investigation timed out after \(Int(timeoutSeconds))s",
                stderrTail: Self.tail(result.stderr)
            )
        }

        guard let wrapper = (try? JSONSerialization.jsonObject(with: result.stdout)) as? [String: Any],
            !wrapper.isEmpty
        else {
            return SemanticInvestigationResult(
                candidateData: nil, sessionId: nil, modelUsed: model, numTurns: nil,
                totalCostUsd: nil, durationMs: elapsedMs, timedOut: false, isError: true,
                errorMessage: "claude did not print a JSON wrapper on stdout",
                stderrTail: Self.tail(result.stderr)
            )
        }

        // `structured_output` is already a `--json-schema`-conformant object when present --
        // confirmed against real Phase 2 runs. Prefer it; fall back to tolerantly extracting
        // `result` text otherwise. `SemanticImporter.ingest` still decodes and validates
        // whichever one this returns unconditionally.
        let candidateData: Data?
        if let structured = wrapper["structured_output"] as? [String: Any] {
            candidateData = try? JSONSerialization.data(withJSONObject: structured)
        } else if let resultText = wrapper["result"] as? String {
            candidateData = Self.extractJSONObject(resultText)
        } else {
            candidateData = nil
        }

        return SemanticInvestigationResult(
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

    private static func errorMessage(_ wrapper: [String: Any]) -> String? {
        if let errors = wrapper["errors"] as? [String], !errors.isEmpty {
            return errors.joined(separator: "; ")
        }
        return wrapper["subtype"] as? String
    }

    private static func extractJSONObject(_ text: String) -> Data? {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end
        else { return nil }
        return text[start...end].data(using: .utf8)
    }

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

enum SemanticInvestigatorError: Error, CustomStringConvertible {
    case schemaEncodingFailed
    var description: String { "failed to encode SemanticSchemaContract.cliJSONSchema() as JSON" }
}

/// The raw result of one `SemanticInvestigator.investigate()` call -- carries no "outcome"
/// verdict of its own, matching `ClaudeCodeInvestigationResult`'s own posture: the verdict is
/// always `SemanticImporter`'s, computed from what actually survives validation (Docs/03 §5).
struct SemanticInvestigationResult: Sendable {
    let candidateData: Data?
    let sessionId: String?
    let modelUsed: String?
    let numTurns: Int?
    let totalCostUsd: Double?
    let durationMs: Double
    let timedOut: Bool
    let isError: Bool
    let errorMessage: String?
    let stderrTail: String
}
