import Foundation
import Observation
import OrionCodeIntel

/// What a completed (or rejected) semantic investigation leaves the app with -- read straight
/// off `SemanticIngestOutcome`, the same counts `orion-index ingest-semantic`'s own
/// `printSummary` reports.
struct SemanticInvestigationSummary: Equatable {
    let outcome: String  // InvestigationOutcome raw value: verified|partially_verified|unverified|rejected
    let componentCount: Int
    let droppedComponentCount: Int
    let duplicateComponentCount: Int
    let componentRelationshipCount: Int
    let unconfirmedComponentRelationshipCount: Int
    let droppedComponentRelationshipCount: Int
    let claimCount: Int
    let contradictedClaimCount: Int
    let droppedClaimCount: Int
    let totalCostUsd: Double?
    let numTurns: Int?
    let durationMs: Double?

    /// Test-only synthetic constructor -- production code only ever builds this from a real
    /// `SemanticIngestOutcome` via the initializer below.
    init(
        outcomeForTesting outcome: String, componentCount: Int, droppedComponentCount: Int,
        duplicateComponentCount: Int, componentRelationshipCount: Int,
        unconfirmedComponentRelationshipCount: Int, droppedComponentRelationshipCount: Int,
        claimCount: Int, contradictedClaimCount: Int, droppedClaimCount: Int,
        totalCostUsd: Double?, numTurns: Int?, durationMs: Double?
    ) {
        self.outcome = outcome
        self.componentCount = componentCount
        self.droppedComponentCount = droppedComponentCount
        self.duplicateComponentCount = duplicateComponentCount
        self.componentRelationshipCount = componentRelationshipCount
        self.unconfirmedComponentRelationshipCount = unconfirmedComponentRelationshipCount
        self.droppedComponentRelationshipCount = droppedComponentRelationshipCount
        self.claimCount = claimCount
        self.contradictedClaimCount = contradictedClaimCount
        self.droppedClaimCount = droppedClaimCount
        self.totalCostUsd = totalCostUsd
        self.numTurns = numTurns
        self.durationMs = durationMs
    }

    init(_ result: SemanticIngestOutcome) {
        let c = result.consistent
        outcome = result.investigation.outcome
        componentCount = c.components.count
        droppedComponentCount = c.droppedComponents.count
        duplicateComponentCount = c.duplicateComponentsDropped.count
        componentRelationshipCount = c.componentRelationships.count
        unconfirmedComponentRelationshipCount = c.componentRelationships.filter {
            $0.confidenceTier == .unresolved
        }.count
        droppedComponentRelationshipCount = c.droppedComponentRelationships.count
        claimCount = c.claims.count
        contradictedClaimCount = c.claims.filter { $0.claimType == .contradicted }.count
        droppedClaimCount = c.droppedClaims.count
        totalCostUsd = result.investigation.totalCostUsd
        numTurns = result.investigation.numTurns
        durationMs = result.investigation.durationMs
    }
}

/// One repository's semantic-investigation lifecycle -- deliberately separate from
/// `RepositorySession`'s own state machine (Docs/13 M3: "If no investigation exists yet, the
/// Architecture Overview screen shows an empty/'not yet built' state instead of blocking
/// repository exploration"). A fresh instance is created per repository, alongside a fresh
/// `AnalysisProgressTracker` in M2's pattern.
@Observable
final class SemanticInvestigationSession {
    enum State: Equatable {
        case idle
        case investigating
        case completed(SemanticInvestigationSummary)
        case failed(String)
    }

    private(set) var state: State = .idle

    func begin() { state = .investigating }
    func succeeded(_ summary: SemanticInvestigationSummary) { state = .completed(summary) }
    func failed(_ message: String) { state = .failed(message) }
    func reset() { state = .idle }
}

enum SemanticInvestigationRunnerError: Error, CustomStringConvertible {
    case noAnalyzedRun
    var description: String { "no analyzed run found -- analyze the repository first" }
}

/// Drives `SemanticInvestigator` (the Claude Code CLI call) then, in-process,
/// `OrionCodeIntel.SemanticImporter.ingest` -- Docs/13_phase4_architecture_ui.md M3's "Build
/// Architecture Model" action. Explicit and user-triggered only (Docs/06 §6 usage constraints);
/// never invoked automatically after analysis.
enum SemanticInvestigationRunner {
    /// - Parameter claudeBinary: forwarded to `SemanticInvestigator`. `nil` (the production
    ///   default) resolves the real installed `claude` CLI via `ClaudeBinaryLocator` -- a GUI
    ///   app's minimal `launchd` environment usually can't find it by bare name (see that type's
    ///   own doc comment for the real bug this fixes). Tests pass an explicit stand-in script
    ///   path, which skips resolution entirely, the same reason `AnalysisRunner.run`'s `resolve`
    ///   parameter exists for testability.
    static func run(
        repoRoot: URL, outputDirectory: URL, session: SemanticInvestigationSession,
        maxBudgetUsd: Double, timeoutSeconds: Double, claudeBinary: String? = nil
    ) async {
        session.begin()
        let resolvedBinary: String
        if let claudeBinary {
            resolvedBinary = claudeBinary
        } else {
            resolvedBinary = await ClaudeBinaryLocator.resolve()
        }
        let investigator = SemanticInvestigator(
            repoRoot: repoRoot, exportDir: outputDirectory.appendingPathComponent("export"),
            maxBudgetUsd: maxBudgetUsd, timeoutSeconds: timeoutSeconds, claudeBinary: resolvedBinary)

        let result: SemanticInvestigationResult
        do {
            result = try await investigator.investigate()
        } catch {
            session.failed(String(describing: error))
            return
        }

        guard !result.timedOut, let candidateData = result.candidateData else {
            session.failed(
                result.errorMessage
                    ?? (result.timedOut ? "investigation timed out" : "claude produced no usable output")
            )
            return
        }

        do {
            let summary = try await Task.detached(priority: .userInitiated) {
                let database = try OrionDatabase(
                    path: outputDirectory.appendingPathComponent("orion.db").path)
                let store = Store(database)
                guard let run = try store.latestRun(commitHash: nil) else {
                    throw SemanticInvestigationRunnerError.noAnalyzedRun
                }

                let candidateURL = outputDirectory.appendingPathComponent("semantic_findings.json")
                try candidateData.write(to: candidateURL)

                var metaURL: URL?
                let metaFields: [String: Any?] = [
                    "model_used": result.modelUsed, "session_id": result.sessionId,
                    "num_turns": result.numTurns, "total_cost_usd": result.totalCostUsd,
                    "duration_ms": result.durationMs, "tools_used": ["Read", "Grep", "Glob"],
                ]
                if let metaData = try? JSONSerialization.data(
                    withJSONObject: metaFields.compactMapValues { $0 })
                {
                    let url = outputDirectory.appendingPathComponent("investigation_meta.json")
                    try metaData.write(to: url)
                    metaURL = url
                }

                let outcome = try SemanticImporter(store: store).ingest(
                    candidateURL: candidateURL, metaURL: metaURL, run: run, now: Timestamp.now())
                return SemanticInvestigationSummary(outcome)
            }.value
            session.succeeded(summary)
        } catch {
            session.failed(String(describing: error))
        }
    }
}
