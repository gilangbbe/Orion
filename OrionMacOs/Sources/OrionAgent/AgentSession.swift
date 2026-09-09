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
    /// Docs/15 §4.5: `ask(_:sessionId:)` never creates a session itself -- a caller passing an
    /// id that doesn't resolve is a caller bug (a stale/deleted session), not something to
    /// silently paper over by starting a fresh one under the hood.
    case sessionNotFound(String)

    public var description: String {
        switch self {
        case .noAnalyzedRun(let path):
            return "no analyzed run found at \(path) -- run `orion-index analyze` first"
        case .sessionNotFound(let id):
            return "no ask session with id \(id) -- create one first (Docs/15 §4.6)"
        }
    }
}

/// The orchestrator Docs/12 M2/M3 both deliberately deferred: wires `DepthModel` -> local
/// `ActionLoop` (depth 1/2) or `ClaudeCodeInvestigator` (depth 3) -> `SemanticImporter` ->
/// `routing_decisions`/`agent_tool_calls` persistence, for one question.
///
/// **Phase 5 (Docs/15 §4) added optional session continuity on top of this, without changing
/// its single-question core**: `ask(_:sessionId:)` still resolves depth and runs exactly one
/// local/delegated investigation per call, same as Docs/12 always intended (a `chat`/REPL loop
/// is still out of scope) -- what's new is that a passed `sessionId` primes that one investigation
/// with the session's prior turns/component context (`ContextBuilder`) and appends this turn to
/// the session afterward (`Store.recordSessionTurn`), rather than each call being fully isolated.
/// A session-less call (`sessionId: nil`, the default) behaves byte-for-byte as it always did.
public struct AgentSession {
    public let config: AgentSessionConfig
    private let sessionFactory: (String?) async throws -> any TurnGenerating
    private let depthFallback: DepthFallbackClassifying

    /// - Parameter sessionFactory: how depth 1/2 obtain a `TurnGenerating` session for
    ///   `ActionLoop` to drive. Defaults to loading the real `Qwen3Agent` (downloads/loads
    ///   weights on first use) -- injectable so `AgentSessionTests` can substitute a scripted
    ///   stub and cover the orchestration (routing/persistence/candidate-JSON construction)
    ///   without a live model, the same seam `ActionLoopTests` already uses for `ActionLoop`
    ///   itself.
    /// - Parameter depthFallback: the Depth Model's non-heuristic classifier. `nil` (the
    ///   default) constructs the real `AppleFoundationDepthClassifier` grounded in this session's
    ///   own `config.repoRoot` -- Docs/15 §11 M8's own real finding: a bare parameter default
    ///   (`= AppleFoundationDepthClassifier()`, what this used to be) has no access to `config`,
    ///   so the classifier never knew *which* repository it was routing for, which was the real
    ///   root cause behind two live false-declines in the M7 benchmark (a question that plainly
    ///   named the analyzed repository read as generic public-library trivia with no signal
    ///   otherwise). Resolved in the initializer body instead of the parameter list specifically
    ///   so `config` is in scope. Still injectable (Docs/15 M1) for the same reason
    ///   `sessionFactory` is: `--force-depth` bypasses `resolveDepth` entirely and so can never
    ///   exercise the guardrail (Docs/15 §3), but a scripted `DepthFallbackClassifying` stub
    ///   lets `AgentSessionTests` drive the real (non-forced) routing path -- including a
    ///   decline -- end to end without a live FoundationModels call.
    public init(
        config: AgentSessionConfig,
        sessionFactory: @escaping (String?) async throws -> any TurnGenerating = { instructions in
            // Docs/12 M6: a silent multi-minute hang on the very first run (real weight,
            // ~4.3GB) reads as a hung CLI, not a slow one -- report real download progress
            // instead of loading silently.
            let reporter = ModelDownloadProgressReporter()
            let agent = try await Qwen3Agent.load(progressHandler: { reporter.report($0) })
            return agent.makeSession(instructions: instructions)
        },
        depthFallback: DepthFallbackClassifying? = nil
    ) {
        self.config = config
        self.sessionFactory = sessionFactory
        self.depthFallback =
            depthFallback ?? AppleFoundationDepthClassifier(repositoryName: config.repoRoot.lastPathComponent)
    }

    /// - Parameter sessionId: `nil` (default) runs a fully independent question, exactly as
    ///   before Phase 5. A real id (from `Store.createAskSession`, Docs/15 §4.6 -- this method
    ///   never creates one itself) primes depth 1/2 with that session's prior turns/component
    ///   context, resumes the session's own Claude conversation for depth 3 when it already has
    ///   one (Docs/15 §4.4, M4), and appends this turn to the session on completion. Ignored for
    ///   the guardrail's own decision (Docs/15 §3.2: a decline never advances a session's turn
    ///   count).
    public func ask(_ question: String, sessionId: String? = nil) async throws -> AgentSessionResult {
        let db = try OrionDatabase(path: config.databasePath.path)
        let store = Store(db)
        guard let run = try store.latestRun(commitHash: config.commit) else {
            throw AgentSessionError.noAnalyzedRun(config.databasePath.path)
        }

        var session: AskSessionRecord? = nil
        var priorTurns: [AskSessionPriorTurn] = []
        var componentContext: String? = nil
        if let sessionId {
            guard let loaded = try store.askSession(id: sessionId) else {
                throw AgentSessionError.sessionNotFound(sessionId)
            }
            session = loaded
            priorTurns = try store.priorTurns(sessionId: sessionId)
            if loaded.scopeType == AskSessionScope.component.rawValue, let componentId = loaded.componentId {
                componentContext = try Self.renderComponentContext(store: store, componentId: componentId)
            }
        }

        let decision = try await resolveDepth(question)

        guard decision.isInScope else {
            // Docs/15 §4.5 step 3: a decline is never appended as a session turn -- an
            // off-topic attempt mid-session doesn't advance `turn_count`/`last_active_at`.
            return try declineOutOfScope(question: question, decision: decision, store: store, run: run)
        }

        let result: AgentSessionResult
        switch decision.depth {
        case 1:
            result = try await runLocal(
                question: question, decision: decision, db: db, store: store, run: run, budget: 0,
                priorTurns: priorTurns, componentContext: componentContext)
        case 2:
            result = try await runLocal(
                question: question, decision: decision, db: db, store: store, run: run,
                budget: config.toolBudget, priorTurns: priorTurns, componentContext: componentContext)
        default:
            result = try await runDelegated(
                question: question, decision: decision, store: store, run: run, session: session)
        }

        if let sessionId {
            try store.recordSessionTurn(
                sessionId: sessionId, investigationId: result.investigation.id,
                claudeSessionId: result.investigation.sessionId, now: Timestamp.now())
        }
        return result
    }

    /// Docs/15 §4.3: a compact members/dependencies/claims block for a component-scoped
    /// session's primed context -- built from `ComponentDetailQuery`, the same relocated query
    /// logic `OrionApp`'s Component Exploration panel uses (Docs/15 M2), not a second copy of it.
    /// `nil` when the component id doesn't resolve (a stale reference to a superseded
    /// investigation, Docs/15 Risk §12.2) rather than throwing -- a session missing its own
    /// component context should still degrade to answering from the whole-repo Code Graph alone,
    /// not fail outright.
    private static func renderComponentContext(store: Store, componentId: String) throws -> String? {
        guard let detail = try ComponentDetailQuery.semanticDetail(store: store, componentId: componentId)
        else { return nil }
        var lines = ["Component: \(detail.name)"]
        if let subtitle = detail.subtitle, !subtitle.isEmpty {
            lines.append("Purpose: \(subtitle)")
        }
        if !detail.members.isEmpty {
            lines.append(
                "Members: " + detail.members.map { "\($0.anchor) (\($0.kind))" }.joined(separator: ", "))
        }
        if !detail.dependencies.isEmpty {
            lines.append(
                "Dependencies: "
                    + detail.dependencies.map { "\($0.targetName) (\($0.type))" }.joined(separator: ", "))
        }
        if !detail.claims.isEmpty {
            lines.append("Known claims:")
            lines.append(contentsOf: detail.claims.map { "- [\($0.claimType)] \($0.statement)" })
        }
        return lines.joined(separator: "\n")
    }

    private func resolveDepth(_ question: String) async throws -> DepthDecision {
        if let forced = config.forceDepth {
            // A deliberate developer override always stays in scope -- Docs/15 §3.2: forcing a
            // depth for debugging must never be silently declined.
            return DepthDecision(
                depth: forced, intent: "forced", confidence: .high,
                rationale: "--force-depth override", method: .heuristic)
        }
        return try await DepthModel(fallback: depthFallback).classify(question)
    }

    /// Docs/15 §3.3: a guardrail decline never loads `Qwen3Agent` or invokes
    /// `ClaudeCodeInvestigator` -- the whole point is that an out-of-scope question costs
    /// nothing and takes no meaningful time. Persists exactly like any other routing decision
    /// (visible via `--explain`/Diagnostics), and one `investigations` row with
    /// `outcome = .declined` -- a correct, complete result, never `partial`.
    private func declineOutOfScope(
        question: String, decision: DepthDecision, store: Store, run: AnalysisRunRecord
    ) throws -> AgentSessionResult {
        let text =
            "I can only help with questions about the analyzed repository. Try asking about"
            + " a specific file, symbol, component, or how something works."
        let record = InvestigationRecord(
            id: DeterministicID.newUUID(), repositoryId: run.repositoryId, commitHash: run.commitHash,
            runId: run.id, question: question, complexity: "none", modelUsed: nil, toolsUsed: [],
            outcome: InvestigationOutcome.declined.rawValue, createdAt: Timestamp.now(),
            answerText: text)
        try store.insertInvestigation(record)
        try persistRouting(decision: decision, investigationId: record.id, store: store)

        return AgentSessionResult(
            question: question, depthDecision: decision, answerText: text, toolCalls: [],
            investigation: record, claimCount: 0, droppedClaimCount: 0, partial: false)
    }

    // MARK: depth 1/2 -- local Qwen3-8B, `ActionLoop` (budget 0 or N)

    private func runLocal(
        question: String, decision: DepthDecision, db: OrionDatabase, store: Store,
        run: AnalysisRunRecord, budget: Int, priorTurns: [AskSessionPriorTurn] = [],
        componentContext: String? = nil
    ) async throws -> AgentSessionResult {
        let tools: [AgentTool] = budget > 0 ? QueryEngineTools.all(engine: QueryEngine(db), commit: config.commit) : []
        let loop = ActionLoop(tools: tools, budget: budget)
        let context = ContextBuilder.build(
            exportDir: config.exportDir, priorTurns: priorTurns, componentContext: componentContext)

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

    /// - Parameter session: `nil` for a session-less call — `.none` continuity,
    ///   `--no-session-persistence`, byte-for-byte the pre-Phase-5 behavior. A real session with
    ///   no `claudeSessionId` yet (its first depth-3 turn) gets `.newSession` (persisted, nothing
    ///   to resume); one that already has a `claudeSessionId` from an earlier depth-3 turn in
    ///   the same session gets `.resume(id)` (Docs/15 §4.4, M4).
    private func runDelegated(
        question: String, decision: DepthDecision, store: Store, run: AnalysisRunRecord,
        session: AskSessionRecord? = nil
    ) async throws -> AgentSessionResult {
        var investigator = ClaudeCodeInvestigator(
            repoRoot: config.repoRoot, exportDir: config.exportDir, model: config.claudeModel,
            claudeBinary: config.claudeBinary)
        investigator.maxBudgetUsd = config.maxBudgetUsd
        investigator.timeoutSeconds = config.timeoutSeconds

        let continuity: ClaudeSessionContinuity
        switch session?.claudeSessionId {
        case .some(let claudeSessionId): continuity = .resume(claudeSessionId)
        case .none: continuity = session == nil ? .none : .newSession
        }
        let investigation = try await investigator.investigate(question: question, continuity: continuity)

        guard !investigation.timedOut, !investigation.isError, let candidateData = investigation.candidateData
        else {
            let text: String
            if investigation.timedOut {
                text = "The Claude Code investigation timed out after \(Int(config.timeoutSeconds))s."
            } else if let reason = investigation.errorMessage {
                // Docs/15_phase5_adaptive_exploration.md §11 M8: the real 55-question benchmark
                // hit this exact wall a second time (XF-01, $1.01 spent at the $1.00 default,
                // Risk #7) -- Docs/12 M5 already hit it once at the previous $0.50 default and
                // fixed it by raising the number, which just deferred the same finding. Rather
                // than guess a new default that will eventually prove too tight again too,
                // surface the actual, immediately actionable fix (the real ceiling that was hit
                // and the flag that controls it) so a developer isn't left to rediscover
                // `--max-budget-usd` from documentation.
                let budgetHint =
                    reason.localizedCaseInsensitiveContains("budget")
                    ? " Configured ceiling was $\(config.maxBudgetUsd); pass a higher"
                        + " --max-budget-usd (`ask`) if this question genuinely needs more turns."
                    : ""
                text = "The Claude Code investigation failed: \(reason)" + budgetHint
            } else {
                text = "The Claude Code investigation failed to produce output. "
                    + "stderr: \(investigation.stderrTail)"
            }
            let record = InvestigationRecord(
                id: DeterministicID.newUUID(), repositoryId: run.repositoryId, commitHash: run.commitHash,
                runId: run.id, question: question, complexity: "high", schemaVersion: nil,
                modelUsed: investigation.modelUsed, toolsUsed: ["Read", "Grep", "Glob"],
                sessionId: investigation.sessionId, numTurns: investigation.numTurns,
                totalCostUsd: investigation.totalCostUsd, durationMs: investigation.durationMs,
                outcome: (investigation.timedOut ? InvestigationOutcome.incomplete : .rejected).rawValue,
                createdAt: Timestamp.now(), answerText: text)
            try store.insertInvestigation(record)
            try persistRouting(decision: decision, investigationId: record.id, store: store)
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
