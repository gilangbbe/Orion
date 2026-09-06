import Foundation
import OrionCodeIntel

/// Everything one `orion-agent ask` invocation needs to find its analyzed repository --
/// mirrors `orion-index`'s own `--out <dir>` convention (`<dir>/orion.db`, `<dir>/export/`), so
/// the two tools point at the same working directory without extra flags.
public struct AgentSessionConfig: Sendable {
    public var repoRoot: URL
    public var outputDirectory: URL
    public var commit: String?
    /// `nil` runs the real Depth Model; a value overrides it (`--force-depth`, Docs/12's CLI
    /// spec) for testing/debugging without needing a question that naturally routes there.
    public var forceDepth: Int?
    /// How many tool calls a depth-2 loop may execute before it must answer (Docs/12 M2).
    public var toolBudget: Int
    public var maxBudgetUsd: Double
    public var timeoutSeconds: Double
    public var claudeBinary: String
    public var claudeModel: String

    public init(
        repoRoot: URL, outputDirectory: URL, commit: String? = nil, forceDepth: Int? = nil,
        toolBudget: Int = 6, maxBudgetUsd: Double = 1.00, timeoutSeconds: Double = 400,
        claudeBinary: String = "claude", claudeModel: String = "claude-sonnet-5"
    ) {
        self.repoRoot = repoRoot
        self.outputDirectory = outputDirectory
        self.commit = commit
        self.forceDepth = forceDepth
        self.toolBudget = toolBudget
        self.maxBudgetUsd = maxBudgetUsd
        self.timeoutSeconds = timeoutSeconds
        self.claudeBinary = claudeBinary
        self.claudeModel = claudeModel
    }

    public var databasePath: URL { outputDirectory.appendingPathComponent("orion.db") }
    public var exportDir: URL { outputDirectory.appendingPathComponent("export") }
}

/// One `ask`'s full result -- enough for the CLI to print both the default view (answer only)
/// and `--explain` (routing decision + tool trace), and to decide its own exit code without
/// re-deriving anything from strings (Docs/12 "CLI").
public struct AgentSessionResult: Sendable {
    public let question: String
    public let depthDecision: DepthDecision
    public let answerText: String
    public let toolCalls: [ExecutedToolCall]
    public let investigation: InvestigationRecord
    public let claimCount: Int
    public let droppedClaimCount: Int
    /// `true` when the answer is known to be incomplete -- a depth-2 loop that ran out of tool
    /// budget, or an L3 investigation that timed out, errored, or failed validation.
    public let partial: Bool
}

public enum AgentSessionError: Error, CustomStringConvertible {
    case noAnalyzedRun(String)

    public var description: String {
        switch self {
        case .noAnalyzedRun(let path):
            return "no analyzed run found at \(path) -- run `orion-index analyze` first"
        }
    }
}

/// The orchestrator Docs/12 M2/M3 both deliberately deferred: wires `DepthModel` -> local
/// `ActionLoop` (depth 1/2) or `ClaudeCodeInvestigator` (depth 3) -> `SemanticImporter` ->
/// `routing_decisions`/`agent_tool_calls` persistence, for one question. Each `ask()` call is
/// self-contained (opens its own `OrionDatabase`) -- no cross-question session state, per
/// Docs/12 "What Phase 3 is not" (a `chat`/REPL is explicitly out of scope).
public struct AgentSession {
    public let config: AgentSessionConfig
    private let sessionFactory: (String?) async throws -> any TurnGenerating

    /// - Parameter sessionFactory: how depth 1/2 obtain a `TurnGenerating` session for
    ///   `ActionLoop` to drive. Defaults to loading the real `Qwen3Agent` (downloads/loads
    ///   weights on first use) -- injectable so `AgentSessionTests` can substitute a scripted
    ///   stub and cover the orchestration (routing/persistence/candidate-JSON construction)
    ///   without a live model, the same seam `ActionLoopTests` already uses for `ActionLoop`
    ///   itself.
    public init(
        config: AgentSessionConfig,
        sessionFactory: @escaping (String?) async throws -> any TurnGenerating = { instructions in
            // Docs/12 M6: a silent multi-minute hang on the very first run (real weight,
            // ~4.3GB) reads as a hung CLI, not a slow one -- report real download progress
            // instead of loading silently.
            let reporter = ModelDownloadProgressReporter()
            let agent = try await Qwen3Agent.load(progressHandler: { reporter.report($0) })
            return agent.makeSession(instructions: instructions)
        }
    ) {
        self.config = config
        self.sessionFactory = sessionFactory
    }

    public func ask(_ question: String) async throws -> AgentSessionResult {
        let db = try OrionDatabase(path: config.databasePath.path)
        let store = Store(db)
        guard let run = try store.latestRun(commitHash: config.commit) else {
            throw AgentSessionError.noAnalyzedRun(config.databasePath.path)
        }

        let decision = try await resolveDepth(question)

        switch decision.depth {
        case 1:
            return try await runLocal(question: question, decision: decision, db: db, store: store, run: run, budget: 0)
        case 2:
            return try await runLocal(
                question: question, decision: decision, db: db, store: store, run: run,
                budget: config.toolBudget)
        default:
            return try await runDelegated(question: question, decision: decision, store: store, run: run)
        }
    }

    private func resolveDepth(_ question: String) async throws -> DepthDecision {
        if let forced = config.forceDepth {
            return DepthDecision(
                depth: forced, intent: "forced", confidence: .high,
                rationale: "--force-depth override", method: .heuristic)
        }
        return try await DepthModel(fallback: AppleFoundationDepthClassifier()).classify(question)
    }

    // MARK: depth 1/2 -- local Qwen3-8B, `ActionLoop` (budget 0 or N)

    private func runLocal(
        question: String, decision: DepthDecision, db: OrionDatabase, store: Store,
        run: AnalysisRunRecord, budget: Int
    ) async throws -> AgentSessionResult {
        let tools: [AgentTool] = budget > 0 ? QueryEngineTools.all(engine: QueryEngine(db), commit: config.commit) : []
        let loop = ActionLoop(tools: tools, budget: budget)
        let context = ContextBuilder.build(exportDir: config.exportDir)

        let session = try await sessionFactory(loop.instructions(context: context))
        let answer = try await loop.run(question: question, session: session)

        let evidence = EvidenceAnchors.extract(from: answer.toolCalls)
        let candidateData = try Self.buildCandidateJSON(
            answer: answer.text, evidence: evidence, confidence: decision.confidence.rawValue,
            assertClaim: budget > 0)
        let meta = InvestigationMeta(
            modelUsed: Qwen3Agent.modelConfiguration.name, sessionId: nil,
            numTurns: answer.toolCalls.count, totalCostUsd: 0, durationMs: nil,
            toolsUsed: tools.map { $0.name })

        let ingestOutcome = try SemanticImporter(store: store).ingestAnswer(
            candidateData: candidateData, meta: meta, question: question, run: run,
            now: Timestamp.now(), complexity: Self.complexity(forDepth: decision.depth),
            createdBy: "qwen3_local")

        try persistRouting(decision: decision, investigationId: ingestOutcome.investigation.id, store: store)
        try persistToolCalls(answer.toolCalls, investigationId: ingestOutcome.investigation.id, store: store)

        return AgentSessionResult(
            question: question, depthDecision: decision, answerText: answer.text,
            toolCalls: answer.toolCalls, investigation: ingestOutcome.investigation,
            claimCount: ingestOutcome.consistent.claims.count,
            droppedClaimCount: ingestOutcome.consistent.droppedClaims.count,
            partial: answer.partial)
    }

    /// Wraps a local answer in the same `phase3.v1` shape a Claude-delegated one already
    /// produces, so both flow through the identical `ingestAnswer` validation/persistence path
    /// (Docs/12 M4). Deliberately does not ask Qwen3-8B itself to emit `claims`/`evidence`
    /// JSON -- Risk #3 already showed this model is unreliable at extra structured fields;
    /// instead one claim is synthesized here in Swift from the loop's own tool-call trace, and
    /// `SemanticImporter`'s existing evidence resolution (which drops any anchor that doesn't
    /// resolve, exactly as it would a Claude-invented one) is what actually decides whether it
    /// survives.
    ///
    /// `assertClaim` (`budget > 0`, i.e. depth 2) controls whether a claim is submitted at all
    /// even when `evidence` came back empty: a depth-1 answer never had tools to ground itself
    /// in, so asserting nothing is correct and `classifyAnswerOutcome` reports `.verified`
    /// ("nothing was asserted, so nothing failed"); a depth-2 answer *did* call tools, so a
    /// claim with no resolvable evidence is submitted anyway and gets dropped, reporting
    /// `.unverified` -- a real, visible difference from "never tried," not the same outcome.
    private static func buildCandidateJSON(
        answer: String, evidence: [String], confidence: String, assertClaim: Bool
    ) throws -> Data {
        let answerText = answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "(the model returned no answer text)" : answer
        let claims: [[String: Any]] =
            assertClaim
            ? [
                [
                    "claim_type": "INTERPRETATION",
                    "statement": answerText,
                    "evidence": evidence,
                    "confidence": confidence,
                ]
            ]
            : []
        let object: [String: Any] = [
            "schema_version": AgentAnswerSchema.currentVersion,
            "answer": answerText,
            "claims": claims,
            "uncertainties": [],
        ]
        return try JSONSerialization.data(withJSONObject: object)
    }

    private static func complexity(forDepth depth: Int) -> String {
        switch depth {
        case 1: return "low"
        case 2: return "medium"
        default: return "high"
        }
    }

    // MARK: depth 3 -- delegate to Claude Code

    private func runDelegated(
        question: String, decision: DepthDecision, store: Store, run: AnalysisRunRecord
    ) async throws -> AgentSessionResult {
        var investigator = ClaudeCodeInvestigator(
            repoRoot: config.repoRoot, exportDir: config.exportDir, model: config.claudeModel,
            claudeBinary: config.claudeBinary)
        investigator.maxBudgetUsd = config.maxBudgetUsd
        investigator.timeoutSeconds = config.timeoutSeconds

        let investigation = try await investigator.investigate(question: question)

        guard !investigation.timedOut, !investigation.isError, let candidateData = investigation.candidateData
        else {
            let record = InvestigationRecord(
                id: DeterministicID.newUUID(), repositoryId: run.repositoryId, commitHash: run.commitHash,
                runId: run.id, question: question, complexity: "high", schemaVersion: nil,
                modelUsed: investigation.modelUsed, toolsUsed: ["Read", "Grep", "Glob"],
                sessionId: investigation.sessionId, numTurns: investigation.numTurns,
                totalCostUsd: investigation.totalCostUsd, durationMs: investigation.durationMs,
                outcome: (investigation.timedOut ? InvestigationOutcome.incomplete : .rejected).rawValue,
                createdAt: Timestamp.now())
            try store.insertInvestigation(record)
            try persistRouting(decision: decision, investigationId: record.id, store: store)
            let text: String
            if investigation.timedOut {
                text = "The Claude Code investigation timed out after \(Int(config.timeoutSeconds))s."
            } else if let reason = investigation.errorMessage {
                text = "The Claude Code investigation failed: \(reason)"
            } else {
                text = "The Claude Code investigation failed to produce output. "
                    + "stderr: \(investigation.stderrTail)"
            }
            return AgentSessionResult(
                question: question, depthDecision: decision, answerText: text, toolCalls: [],
                investigation: record, claimCount: 0, droppedClaimCount: 0, partial: true)
        }

        do {
            let ingestOutcome = try SemanticImporter(store: store).ingestAnswer(
                candidateData: candidateData, meta: investigation.investigationMeta,
                question: question, run: run, now: Timestamp.now())
            try persistRouting(decision: decision, investigationId: ingestOutcome.investigation.id, store: store)
            return AgentSessionResult(
                question: question, depthDecision: decision,
                answerText: ingestOutcome.answer ?? "(no answer text)", toolCalls: [],
                investigation: ingestOutcome.investigation,
                claimCount: ingestOutcome.consistent.claims.count,
                droppedClaimCount: ingestOutcome.consistent.droppedClaims.count,
                partial: ingestOutcome.investigation.outcome != InvestigationOutcome.verified.rawValue)
        } catch let error as SemanticImportError {
            let (record, message): (InvestigationRecord, String)
            switch error {
            case .decodeFailed(let underlying, let inv):
                (record, message) = (inv, "Claude's answer did not decode as valid JSON: \(underlying)")
            case .schemaInvalid(let errors, let inv):
                (record, message) = (
                    inv, "Claude's answer failed schema validation: \(errors.joined(separator: "; "))"
                )
            }
            try persistRouting(decision: decision, investigationId: record.id, store: store)
            return AgentSessionResult(
                question: question, depthDecision: decision, answerText: message, toolCalls: [],
                investigation: record, claimCount: 0, droppedClaimCount: 0, partial: true)
        }
    }

    // MARK: shared persistence

    private func persistRouting(decision: DepthDecision, investigationId: String, store: Store) throws {
        try store.insertRoutingDecision(
            RoutingDecisionRecord(
                id: DeterministicID.newUUID(), investigationId: investigationId,
                depthLevel: decision.depth, method: decision.method.rawValue,
                confidence: decision.confidence.rawValue, rationale: decision.rationale,
                createdAt: Timestamp.now()))
    }

    private func persistToolCalls(
        _ calls: [ExecutedToolCall], investigationId: String, store: Store
    ) throws {
        for call in calls {
            try store.insertAgentToolCall(
                AgentToolCallRecord(
                    id: DeterministicID.newUUID(), investigationId: investigationId,
                    turnIndex: call.turnIndex, toolName: call.toolName,
                    arguments: call.argumentsDescription,
                    resultSummary: String(call.result.prefix(2000)), latencyMs: nil,
                    createdAt: Timestamp.now()))
        }
    }
}
