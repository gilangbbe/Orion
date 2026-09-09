import Foundation
import OrionCodeIntel

/// Thin read-only wrapper over `OrionCodeIntel.Store`'s existing read methods
/// (Docs/13_phase4_architecture_ui.md M3) -- no new `Store` API was needed, it already exposes
/// everything Phase 4's screens read: symbols/relationships (Phase 1), components/
/// component_relationships/claims/evidence/investigations (Phase 2). Opens its own
/// `OrionDatabase` handle per call rather than holding one open long-term, matching
/// `AnalysisRunner`/`SemanticInvestigationRunner`'s own pattern.
struct CodebaseModelStore {
    let databasePath: URL

    init(outputDirectory: URL) {
        databasePath = outputDirectory.appendingPathComponent("orion.db")
    }

    private func store() throws -> Store {
        Store(try OrionDatabase(path: databasePath.path))
    }

    // MARK: Phase 1 -- structural (FACT-tier)

    func latestRun(commitHash: String? = nil) throws -> AnalysisRunRecord? {
        try store().latestRun(commitHash: commitHash)
    }

    func repository(id: String) throws -> RepositoryRecord? {
        try store().repository(id: id)
    }

    func parseOkCount(runId: String) throws -> Int {
        try store().parseOkCount(runId: runId)
    }

    func symbols(runId: String) throws -> [SymbolRecord] {
        try store().symbols(runId: runId)
    }

    func symbol(runId: String, anchor: String) throws -> SymbolRecord? {
        try store().symbol(runId: runId, anchor: anchor)
    }

    func relationships(runId: String) throws -> [RelationshipRecord] {
        try store().relationships(runId: runId)
    }

    // MARK: Phase 2 -- semantic (INTERPRETATION/INFERENCE-tier)

    func latestInvestigation(runId: String) throws -> InvestigationRecord? {
        try store().latestInvestigation(runId: runId)
    }

    /// Every investigation ever ingested for this run, oldest first -- an audit trail, like
    /// `investigations.jsonl` (Docs/11), not just the current semantic model.
    func investigations(runId: String) throws -> [InvestigationRecord] {
        try store().investigations(runId: runId)
    }

    func components(investigationId: String) throws -> [ComponentRecord] {
        try store().components(investigationId: investigationId)
    }

    func componentMembers(componentIds: [String]) throws -> [ComponentMemberRecord] {
        try store().componentMembers(componentIds: componentIds)
    }

    func componentRelationships(investigationId: String) throws -> [ComponentRelationshipRecord] {
        try store().componentRelationships(investigationId: investigationId)
    }

    func claims(investigationId: String) throws -> [ClaimRecord] {
        try store().claims(investigationId: investigationId)
    }

    func evidence(claimIds: [String]) throws -> [EvidenceRecord] {
        try store().evidence(claimIds: claimIds)
    }

    // MARK: Phase 5 -- conversational sessions (Docs/15_phase5_adaptive_exploration.md M6)

    func investigation(id: String) throws -> InvestigationRecord? {
        try store().investigation(id: id)
    }

    func routingDecisions(investigationId: String) throws -> [RoutingDecisionRecord] {
        try store().routingDecisions(investigationId: investigationId)
    }

    func component(id: String) throws -> ComponentRecord? {
        try store().component(id: id)
    }

    func askSessions(repositoryId: String, commitHash: String) throws -> [AskSessionRecord] {
        try store().askSessions(repositoryId: repositoryId, commitHash: commitHash)
    }

    func askSessionTurns(sessionId: String) throws -> [AskSessionTurnRecord] {
        try store().askSessionTurns(sessionId: sessionId)
    }
}
