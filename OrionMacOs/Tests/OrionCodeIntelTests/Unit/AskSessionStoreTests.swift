import XCTest
import GRDB
@testable import OrionCodeIntel

/// Docs/15_phase5_adaptive_exploration.md M3: the real lifecycle logic composed out of M0's bare
/// CRUD primitives -- `createAskSession`'s scope/`componentId` invariant, `recordSessionTurn`'s
/// atomic turn-insert-plus-activity-update, and `priorTurns`' bounding/ordering. Complements
/// `AskSessionSchemaTests` (M0's own migration/CRUD round-trip coverage), not a duplicate of it.
final class AskSessionStoreTests: XCTestCase {

    /// A minimal, FK-satisfying chain (repository -> run -> investigation, plus one component)
    /// mirroring `AskSessionSchemaTests`' own fixture.
    private func seeded() throws -> (db: OrionDatabase, componentId: String) {
        let db = try OrionDatabase(inMemory: true)
        try db.dbQueue.write { dbc in
            try RepositoryRecord(
                id: "repo", sourceURL: nil, localPath: "/x", commitHash: "c0ffee",
                languages: ["python"], analysisStatus: .succeeded, createdAt: "t0", updatedAt: "t0"
            ).insert(dbc)
            try AnalysisRunRecord(
                id: "run", repositoryId: "repo", commitHash: "c0ffee", status: "succeeded",
                startedAt: "t0", finishedAt: "t1", orionVersion: "0.1.0", resolver: "none",
                grammarVersions: [:], toolVersions: [:], stageTimings: [:], fileCount: 0,
                symbolCount: 0, relationshipCount: 0, diagnosticCount: 0, error: nil
            ).insert(dbc)
            try InvestigationRecord(
                id: "inv0", repositoryId: "repo", commitHash: "c0ffee", runId: "run",
                question: "phase2_semantic_grouping", complexity: "high", outcome: "verified",
                createdAt: "t0"
            ).insert(dbc)
            try ComponentRecord(
                id: "comp1", repositoryId: "repo", commitHash: "c0ffee", runId: "run",
                investigationId: "inv0", name: "Authentication", description: "Auth stuff.",
                architecturalRole: "core", confidence: 0.9, confidenceTier: "high",
                status: "active", epistemicType: "INTERPRETATION", provenance: "claude_code"
            ).insert(dbc)
        }
        return (db, "comp1")
    }

    private func makeInvestigation(
        db: OrionDatabase, id: String, question: String, answerText: String?,
        outcome: String = "verified"
    ) throws {
        try db.dbQueue.write { dbc in
            try InvestigationRecord(
                id: id, repositoryId: "repo", commitHash: "c0ffee", runId: "run", question: question,
                complexity: "low", outcome: outcome, createdAt: "t0", answerText: answerText
            ).insert(dbc)
        }
    }

    // MARK: createAskSession

    func testCreateRepositoryScopedSession() throws {
        let (db, _) = try seeded()
        let store = Store(db)
        let session = try store.createAskSession(
            repositoryId: "repo", commitHash: "c0ffee", scopeType: .repository,
            title: "General questions", now: "t0")
        XCTAssertEqual(session.scopeType, "repository")
        XCTAssertNil(session.componentId)
        XCTAssertEqual(session.turnCount, 0)
        XCTAssertEqual(try store.askSession(id: session.id)?.title, "General questions")
    }

    func testCreateComponentScopedSession() throws {
        let (db, componentId) = try seeded()
        let store = Store(db)
        let session = try store.createAskSession(
            repositoryId: "repo", commitHash: "c0ffee", scopeType: .component,
            componentId: componentId, title: "About Authentication", now: "t0")
        XCTAssertEqual(session.scopeType, "component")
        XCTAssertEqual(session.componentId, componentId)
    }

    func testCreateComponentScopedSessionWithoutComponentIdThrows() throws {
        let (db, _) = try seeded()
        let store = Store(db)
        XCTAssertThrowsError(
            try store.createAskSession(
                repositoryId: "repo", commitHash: "c0ffee", scopeType: .component, title: "x",
                now: "t0")
        ) { error in
            guard case AskSessionError.componentRequiredForComponentScope = error else {
                return XCTFail("expected componentRequiredForComponentScope, got \(error)")
            }
        }
    }

    func testCreateRepositoryScopedSessionWithComponentIdThrows() throws {
        let (db, componentId) = try seeded()
        let store = Store(db)
        XCTAssertThrowsError(
            try store.createAskSession(
                repositoryId: "repo", commitHash: "c0ffee", scopeType: .repository,
                componentId: componentId, title: "x", now: "t0")
        ) { error in
            guard case AskSessionError.componentNotAllowedForRepositoryScope = error else {
                return XCTFail("expected componentNotAllowedForRepositoryScope, got \(error)")
            }
        }
    }

    // MARK: recordSessionTurn

    func testRecordSessionTurnAppendsAndBumpsActivity() throws {
        let (db, _) = try seeded()
        let store = Store(db)
        let session = try store.createAskSession(
            repositoryId: "repo", commitHash: "c0ffee", scopeType: .repository, title: "x", now: "t0")
        try makeInvestigation(db: db, id: "inv1", question: "Q1", answerText: "A1")

        let turn = try store.recordSessionTurn(
            sessionId: session.id, investigationId: "inv1", claudeSessionId: nil, now: "t1")
        XCTAssertEqual(turn.turnIndex, 0)

        let updated = try store.askSession(id: session.id)
        XCTAssertEqual(updated?.turnCount, 1)
        XCTAssertEqual(updated?.lastActiveAt, "t1")
        XCTAssertNil(updated?.claudeSessionId)
    }

    func testRecordSessionTurnIndexesIncrementSequentially() throws {
        let (db, _) = try seeded()
        let store = Store(db)
        let session = try store.createAskSession(
            repositoryId: "repo", commitHash: "c0ffee", scopeType: .repository, title: "x", now: "t0")
        try makeInvestigation(db: db, id: "inv1", question: "Q1", answerText: "A1")
        try makeInvestigation(db: db, id: "inv2", question: "Q2", answerText: "A2")

        let turn1 = try store.recordSessionTurn(
            sessionId: session.id, investigationId: "inv1", claudeSessionId: nil, now: "t1")
        let turn2 = try store.recordSessionTurn(
            sessionId: session.id, investigationId: "inv2", claudeSessionId: nil, now: "t2")

        XCTAssertEqual(turn1.turnIndex, 0)
        XCTAssertEqual(turn2.turnIndex, 1)
        XCTAssertEqual(try store.askSession(id: session.id)?.turnCount, 2)
    }

    func testRecordSessionTurnPreservesClaudeSessionIdWhenPassedNil() throws {
        let (db, _) = try seeded()
        let store = Store(db)
        let session = try store.createAskSession(
            repositoryId: "repo", commitHash: "c0ffee", scopeType: .repository, title: "x", now: "t0")
        try makeInvestigation(db: db, id: "inv1", question: "Q1", answerText: "A1")
        try makeInvestigation(db: db, id: "inv2", question: "Q2", answerText: "A2")

        try store.recordSessionTurn(
            sessionId: session.id, investigationId: "inv1", claudeSessionId: "claude-abc", now: "t1")
        XCTAssertEqual(try store.askSession(id: session.id)?.claudeSessionId, "claude-abc")

        // A later local-model turn (no Claude session id of its own) must not clear it.
        try store.recordSessionTurn(
            sessionId: session.id, investigationId: "inv2", claudeSessionId: nil, now: "t2")
        XCTAssertEqual(try store.askSession(id: session.id)?.claudeSessionId, "claude-abc")
    }

    func testRecordSessionTurnForMissingSessionThrows() throws {
        let (db, _) = try seeded()
        let store = Store(db)
        try makeInvestigation(db: db, id: "inv1", question: "Q1", answerText: "A1")
        XCTAssertThrowsError(
            try store.recordSessionTurn(
                sessionId: "no-such-session", investigationId: "inv1", claudeSessionId: nil, now: "t1")
        ) { error in
            guard case AskSessionError.sessionNotFound("no-such-session") = error else {
                return XCTFail("expected sessionNotFound, got \(error)")
            }
        }
    }

    // MARK: priorTurns

    func testPriorTurnsOrderedOldestFirst() throws {
        let (db, _) = try seeded()
        let store = Store(db)
        let session = try store.createAskSession(
            repositoryId: "repo", commitHash: "c0ffee", scopeType: .repository, title: "x", now: "t0")
        try makeInvestigation(db: db, id: "inv1", question: "Q1", answerText: "A1")
        try makeInvestigation(db: db, id: "inv2", question: "Q2", answerText: "A2")
        try store.recordSessionTurn(
            sessionId: session.id, investigationId: "inv1", claudeSessionId: nil, now: "t1")
        try store.recordSessionTurn(
            sessionId: session.id, investigationId: "inv2", claudeSessionId: nil, now: "t2")

        let turns = try store.priorTurns(sessionId: session.id)
        XCTAssertEqual(turns.map(\.question), ["Q1", "Q2"])
        XCTAssertEqual(turns.map(\.answerText), ["A1", "A2"])
    }

    func testPriorTurnsBoundedToLimit() throws {
        let (db, _) = try seeded()
        let store = Store(db)
        let session = try store.createAskSession(
            repositoryId: "repo", commitHash: "c0ffee", scopeType: .repository, title: "x", now: "t0")
        for i in 1...7 {
            try makeInvestigation(db: db, id: "inv\(i)", question: "Q\(i)", answerText: "A\(i)")
            try store.recordSessionTurn(
                sessionId: session.id, investigationId: "inv\(i)", claudeSessionId: nil, now: "t\(i)")
        }

        let turns = try store.priorTurns(sessionId: session.id, limit: 5)
        // The 5 most recent, oldest first: Q3..Q7.
        XCTAssertEqual(turns.map(\.question), ["Q3", "Q4", "Q5", "Q6", "Q7"])
    }

    func testPriorTurnsFallsBackToPlaceholderWhenAnswerTextMissing() throws {
        let (db, _) = try seeded()
        let store = Store(db)
        let session = try store.createAskSession(
            repositoryId: "repo", commitHash: "c0ffee", scopeType: .repository, title: "x", now: "t0")
        // A Phase-2-style investigation (whole-repo grouping) never has an answer_text.
        try makeInvestigation(db: db, id: "inv1", question: "phase2_semantic_grouping", answerText: nil)
        try store.recordSessionTurn(
            sessionId: session.id, investigationId: "inv1", claudeSessionId: nil, now: "t1")

        let turns = try store.priorTurns(sessionId: session.id)
        XCTAssertEqual(turns.first?.answerText, "(no answer recorded)")
    }

    func testPriorTurnsEmptyForANewSession() throws {
        let (db, _) = try seeded()
        let store = Store(db)
        let session = try store.createAskSession(
            repositoryId: "repo", commitHash: "c0ffee", scopeType: .repository, title: "x", now: "t0")
        XCTAssertEqual(try store.priorTurns(sessionId: session.id), [])
    }
}
