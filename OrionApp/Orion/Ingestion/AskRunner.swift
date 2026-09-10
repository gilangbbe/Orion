import Foundation
import OrionAgent
import OrionCodeIntel

struct AskToolCallSummary: Identifiable, Equatable {
    let id = UUID()
    let turnIndex: Int
    let toolName: String
    let arguments: String
    let result: String
}

/// One surviving claim from the answer, with clickable evidence -- `AgentSessionResult` itself
/// only reports counts (`claimCount`/`droppedClaimCount`), not the claims (Docs/12 M4: "revisit
/// once M5's hand-picked validation shows whether that detail is actually needed"); Phase 4
/// answers that need by reading the same `investigation_id` back through `CodebaseModelStore`,
/// reusing the exact infrastructure Component Exploration (M5) already built rather than
/// widening Phase 3's own API.
struct AskClaimSummary: Identifiable, Equatable {
    let id: String
    let statement: String
    let claimType: String
    let confidence: String
    let evidence: [EvidenceDetail]
    /// Docs/16_phase6_continuous_model_updates.md §8, M5 -- see `ComponentClaimDetail`'s own
    /// identical field for the full reasoning (the "Superseded — see Model Changes"
    /// cross-reference, Docs/14 §2).
    let reversedByRevisionId: String?
}

/// A UI-friendly projection of `OrionAgent.AgentSessionResult` -- Docs/13_phase4_architecture_ui.md
/// M7.
struct AskResultSummary: Equatable {
    let answerText: String
    let depth: Int
    let routingMethod: String
    let routingConfidence: String
    let rationale: String
    let outcome: String
    let claimCount: Int
    let droppedClaimCount: Int
    let partial: Bool
    let toolCalls: [AskToolCallSummary]
    let claims: [AskClaimSummary]

    /// Docs/12 Risk #5's own finding, left for Phase 4 to actually fix at the UX layer: a
    /// depth-1 answer that asserted zero claims is reported `verified` (nothing was asserted, so
    /// nothing failed to substantiate) -- correct as a label, but easy to misread as "checked and
    /// correct" when M5's real validation found it was factually wrong 4 times out of 4. This is
    /// the one flag `AskEntryView` uses to render that case with a visibly different treatment.
    var isUngroundedVerified: Bool { depth == 1 && claimCount == 0 }

    /// Docs/15_phase5_adaptive_exploration.md §3.3/§7 (M6): a guardrail decline is a correct,
    /// complete result, not a failure -- checked *before* `isUngroundedVerified`/`partial` by
    /// every view that renders an outcome, so it never gets the orange "partial" treatment or
    /// the green verified seal.
    var isDeclined: Bool { outcome == InvestigationOutcome.declined.rawValue }

    init(_ result: AgentSessionResult, claims: [AskClaimSummary] = []) {
        answerText = result.answerText
        depth = result.depthDecision.depth
        routingMethod = result.depthDecision.method.rawValue
        routingConfidence = result.depthDecision.confidence.rawValue
        rationale = result.depthDecision.rationale
        outcome = result.investigation.outcome
        claimCount = result.claimCount
        droppedClaimCount = result.droppedClaimCount
        partial = result.partial
        toolCalls = result.toolCalls.map {
            AskToolCallSummary(
                turnIndex: $0.turnIndex, toolName: $0.toolName, arguments: $0.argumentsDescription,
                result: $0.result)
        }
        self.claims = claims
    }

    /// Test-support entry point -- Docs/14_phase4_5_ui_ux_redesign.md §8 M8's own finding:
    /// `AgentSessionResult` has no initializer reachable outside `OrionAgent`, so a synthetic
    /// `AskResultSummary` for `DiagnosticsSessionTests` needs its own explicit memberwise init
    /// alongside `init(_ result:claims:)` above (defining that one already suppresses Swift's
    /// synthesized memberwise init).
    init(
        answerText: String, depth: Int, routingMethod: String, routingConfidence: String,
        rationale: String, outcome: String, claimCount: Int, droppedClaimCount: Int, partial: Bool,
        toolCalls: [AskToolCallSummary] = [], claims: [AskClaimSummary] = []
    ) {
        self.answerText = answerText
        self.depth = depth
        self.routingMethod = routingMethod
        self.routingConfidence = routingConfidence
        self.rationale = rationale
        self.outcome = outcome
        self.claimCount = claimCount
        self.droppedClaimCount = droppedClaimCount
        self.partial = partial
        self.toolCalls = toolCalls
        self.claims = claims
    }
}

enum AskOutcome: Equatable {
    case answered(AskResultSummary)
    case failed(String)

    /// Docs/15_phase5_adaptive_exploration.md §4.5/§7: a guardrail decline is a correct, complete
    /// result that's deliberately never persisted as a session turn (`AgentSession.ask` skips
    /// `Store.recordSessionTurn` for it). `AskHistory.ask(_:)` uses this to know when reloading
    /// turns from the database would silently wipe the just-shown decline back out of `turns` --
    /// a real reported bug ("renders something in the chat, but it immediately disappears").
    var isDeclined: Bool {
        if case .answered(let summary) = self { return summary.isDeclined }
        return false
    }
}

/// Drives `OrionAgent.AgentSession.ask(_:)` for one question -- in-process, no CLI subprocess.
/// Each call is independent (Docs/12 "What Phase 3 is not": no cross-question agent memory);
/// `AskView` keeps its own UI-local transcript on top of this.
enum AskRunner {
    /// - Parameter session: injectable for tests (a fake `TurnGenerating` for depth 1/2, or a
    ///   real `AgentSession` pointed at a stand-in `claude` script for depth 3) -- mirrors
    ///   `SemanticInvestigationRunner`'s own `claudeBinary` seam. The production default
    ///   resolves the real `claude` binary path first via `ClaudeBinaryLocator` -- depth-3
    ///   delegation goes through the exact same GUI-app-`PATH` gap `SemanticInvestigator` hit
    ///   (Docs/13 Risk 13), since `AgentSession` builds its own `ClaudeCodeInvestigator`
    ///   internally with whatever `claudeBinary` this config carries.
    /// - Parameter sessionId: `nil` (default, pre-Phase-5 behavior) asks a fully independent
    ///   question. A real id (Docs/15_phase5_adaptive_exploration.md §4/M6) primes this question
    ///   with that session's prior turns/component context and appends this turn to it.
    static func ask(
        question: String, repoRoot: URL, outputDirectory: URL,
        maxBudgetUsd: Double = 1.00, timeoutSeconds: Double = 400,
        sessionId: String? = nil, session: AgentSession? = nil
    ) async -> AskOutcome {
        let agentSession: AgentSession
        if let session {
            agentSession = session
        } else {
            let claudeBinary = await ClaudeBinaryLocator.resolve()
            agentSession = AgentSession(
                config: AgentSessionConfig(
                    repoRoot: repoRoot, outputDirectory: outputDirectory,
                    maxBudgetUsd: maxBudgetUsd, timeoutSeconds: timeoutSeconds,
                    claudeBinary: claudeBinary))
        }

        do {
            let result = try await agentSession.ask(question, sessionId: sessionId)
            // Best-effort: a failure reading claims back shouldn't turn a real, already-obtained
            // answer into an error -- the answer text and counts are already correct either way.
            let claims =
                (try? loadClaims(investigationId: result.investigation.id, outputDirectory: outputDirectory))
                ?? []
            return .answered(AskResultSummary(result, claims: claims))
        } catch {
            return .failed(String(describing: error))
        }
    }

    enum PersistedTurnError: Error, CustomStringConvertible {
        case investigationNotFound(String)
        var description: String {
            switch self {
            case .investigationNotFound(let id): return "no investigation found with id \(id)"
            }
        }
    }

    /// Reconstructs an already-completed turn's `AskResultSummary` from persisted data alone --
    /// no live `AgentSessionResult`, since that type only ever exists transiently right after an
    /// `AgentSession.ask` call returns (Docs/15_phase5_adaptive_exploration.md M6: a session's
    /// past turns are loaded this way when its history is displayed, not re-run). Reuses
    /// `AskResultSummary`'s own "test-support" memberwise init for real reconstruction, not just
    /// tests -- the exact shape it was already built to produce.
    ///
    /// **Known, accepted fidelity gap**: `droppedClaimCount` and the loop-level `partial` flag
    /// (Docs/12 M2's "ran out of tool budget without an explicit answer" signal) are never
    /// persisted anywhere -- only `SemanticImporter.ingestAnswer`'s own resulting `outcome` is.
    /// `droppedClaimCount` reconstructs as `0` (never a false claim of drops that didn't survive);
    /// `partial` is approximated as "outcome is neither verified nor declined," which matches
    /// every real code path except one narrow case (a depth-2 answer that exhausted its tool
    /// budget yet still happened to resolve a clean, `.verified` claim) -- judged not worth a new
    /// persisted column for a single cosmetic "[partial answer]" tag on live-only display.
    static func loadPersistedTurn(
        investigationId: String, outputDirectory: URL
    ) throws -> (question: String, summary: AskResultSummary) {
        let store = CodebaseModelStore(outputDirectory: outputDirectory)
        guard let investigation = try store.investigation(id: investigationId) else {
            throw PersistedTurnError.investigationNotFound(investigationId)
        }
        let routing = try store.routingDecisions(investigationId: investigationId).first
        let claims = try loadClaims(investigationId: investigationId, outputDirectory: outputDirectory)
        let summary = AskResultSummary(
            answerText: investigation.answerText ?? "(no answer recorded)",
            depth: routing?.depthLevel ?? 0, routingMethod: routing?.method ?? "unknown",
            routingConfidence: routing?.confidence ?? "unknown", rationale: routing?.rationale ?? "",
            outcome: investigation.outcome, claimCount: claims.count, droppedClaimCount: 0,
            partial: ![InvestigationOutcome.verified.rawValue, InvestigationOutcome.declined.rawValue]
                .contains(investigation.outcome),
            claims: claims)
        return (investigation.question, summary)
    }

    private static func loadClaims(
        investigationId: String, outputDirectory: URL
    ) throws -> [AskClaimSummary] {
        let store = CodebaseModelStore(outputDirectory: outputDirectory)
        let claims = try store.claims(investigationId: investigationId)
        let evidence = try store.evidence(claimIds: claims.map(\.id))
        let evidenceByClaimId = Dictionary(grouping: evidence, by: \.claimId)
        return try claims.map { claim in
            let reversedBy = try store.modelRevisionEntries(relatedClaimId: claim.id)
                .first { $0.changeType == ModelRevisionChangeType.reversed.rawValue }?
                .modelRevisionId
            return AskClaimSummary(
                id: claim.id, statement: claim.statement, claimType: claim.claimType,
                confidence: ConfidenceBadge.tierLabel(forScore: claim.confidence),
                evidence: (evidenceByClaimId[claim.id] ?? []).map {
                    EvidenceDetail(id: $0.id, anchor: $0.anchor, startLine: $0.startLine, endLine: $0.endLine)
                }, reversedByRevisionId: reversedBy)
        }
    }
}
