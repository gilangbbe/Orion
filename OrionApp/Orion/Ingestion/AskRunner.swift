import Foundation
import OrionAgent
import OrionCodeIntel

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
                (try? AskTurnLoader.loadClaims(investigationId: result.investigation.id, outputDirectory: outputDirectory))
                ?? []
            return .answered(AskResultSummary(result, claims: claims))
        } catch {
            return .failed(String(describing: error))
        }
    }

    typealias PersistedTurnError = AskTurnLoader.PersistedTurnError

    /// Kept as the Mac's entry point; the loading itself is shared with the iOS companion
    /// (`AskTurnLoader`, Docs/19 M6).
    static func loadPersistedTurn(
        investigationId: String, outputDirectory: URL
    ) throws -> (question: String, summary: AskResultSummary) {
        try AskTurnLoader.loadPersistedTurn(investigationId: investigationId, outputDirectory: outputDirectory)
    }
}
