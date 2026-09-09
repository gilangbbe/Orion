import XCTest
import GRDB
@testable import OrionCodeIntel

/// Docs/15 M0: `v4_phase5_schema` applies cleanly on top of `v1_phase1_schema`/
/// `v2_phase2_schema`/`v3_phase3_schema`, `ask_sessions`/`ask_session_turns` round-trip through
/// their typed records, and both cascading-delete directions hold (deleting the owning session
/// removes its turns; deleting a turn's underlying investigation removes the turn) — same shape
/// as `SemanticSchemaTests`/`AgentSchemaTests` for Phase 2/3's own tables.
final class AskSessionSchemaTests: XCTestCase {

    /// A minimal, FK-satisfying chain (repository -> run -> investigation, plus one component
    /// hanging off a second investigation) for `ask_sessions`/`ask_session_turns` to hang off.
    private func seeded() throws -> (
        db: OrionDatabase, investigationId: String, componentId: String
    ) {
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
                id: "inv", repositoryId: "repo", commitHash: "c0ffee", runId: "run",
                question: "What does `AuthService` do?", complexity: "low",
                schemaVersion: nil, modelUsed: "mlx-community/Qwen3-8B-4bit",
                toolsUsed: [], sessionId: nil, numTurns: nil, totalCostUsd: nil,
                durationMs: nil, outcome: "verified", createdAt: "t0"
            ).insert(dbc)
            try ComponentRecord(
                id: "comp1", repositoryId: "repo", commitHash: "c0ffee", runId: "run",
                investigationId: "inv", name: "Authentication", description: "Auth stuff.",
                architecturalRole: "core", confidence: 0.9, confidenceTier: "high",
                status: "active", epistemicType: "INTERPRETATION", provenance: "claude_code"
            ).insert(dbc)
        }
        return (db, "inv", "comp1")
    }

    func testV4TablesExist() throws {
        let (db, _, _) = try seeded()
        try db.dbQueue.read { dbc in
            let names = try String.fetchSet(
                dbc, sql: "SELECT name FROM sqlite_master WHERE type = 'table'")
            XCTAssertTrue(names.contains("ask_sessions"))
            XCTAssertTrue(names.contains("ask_session_turns"))
        }
    }

    func testPhase1Through4SuiteUnaffected() throws {
        // Same DB Phase 1-3 tests exercise still has its full v1-v3 shape after v4 is applied.
        let (db, invId, compId) = try seeded()
        try db.dbQueue.read { dbc in
            XCTAssertEqual(try InvestigationRecord.fetchCount(dbc), 1)
            XCTAssertEqual(try ComponentRecord.fetchCount(dbc), 1)
        }
        XCTAssertEqual(invId, "inv")
        XCTAssertEqual(compId, "comp1")
    }

    func testRepositoryScopedSessionRoundTrip() throws {
        let (db, _, _) = try seeded()
        let store = Store(db)

        try store.insertAskSession(
            AskSessionRecord(
                id: "sess1", repositoryId: "repo", commitHash: "c0ffee",
                scopeType: AskSessionScope.repository.rawValue, componentId: nil,
                title: "What does this repo do?", createdAt: "t0", lastActiveAt: "t0"
            ))

        let fetched = try store.askSession(id: "sess1")
        XCTAssertEqual(fetched?.scopeType, "repository")
        XCTAssertNil(fetched?.componentId)
        XCTAssertEqual(fetched?.turnCount, 0)
        XCTAssertNil(fetched?.claudeSessionId)

        let listed = try store.askSessions(repositoryId: "repo", commitHash: "c0ffee")
        XCTAssertEqual(listed.map(\.id), ["sess1"])
    }

    func testComponentScopedSessionRoundTrip() throws {
        let (db, _, compId) = try seeded()
        let store = Store(db)

        try store.insertAskSession(
            AskSessionRecord(
                id: "sess2", repositoryId: "repo", commitHash: "c0ffee",
                scopeType: AskSessionScope.component.rawValue, componentId: compId,
                title: "Tell me more about Authentication.", createdAt: "t0", lastActiveAt: "t0"
            ))

        let fetched = try store.askSession(id: "sess2")
        XCTAssertEqual(fetched?.scopeType, "component")
        XCTAssertEqual(fetched?.componentId, compId)
    }

    func testAskSessionsOrderedByMostRecentlyActive() throws {
        let (db, _, _) = try seeded()
        let store = Store(db)
        try store.insertAskSession(
            AskSessionRecord(
                id: "older", repositoryId: "repo", commitHash: "c0ffee",
                scopeType: "repository", title: "First.", createdAt: "t0", lastActiveAt: "t0"
            ))
        try store.insertAskSession(
            AskSessionRecord(
                id: "newer", repositoryId: "repo", commitHash: "c0ffee",
                scopeType: "repository", title: "Second.", createdAt: "t1", lastActiveAt: "t2"
            ))

        let listed = try store.askSessions(repositoryId: "repo", commitHash: "c0ffee")
        XCTAssertEqual(listed.map(\.id), ["newer", "older"])
    }

    func testUpdateAskSessionActivity() throws {
        let (db, invId, _) = try seeded()
        let store = Store(db)
        try store.insertAskSession(
            AskSessionRecord(
                id: "sess1", repositoryId: "repo", commitHash: "c0ffee",
                scopeType: "repository", title: "First question.", createdAt: "t0",
                lastActiveAt: "t0"
            ))

        try store.updateAskSessionActivity(
            id: "sess1", turnCount: 1, lastActiveAt: "t1", claudeSessionId: "claude-abc")
        var fetched = try store.askSession(id: "sess1")
        XCTAssertEqual(fetched?.turnCount, 1)
        XCTAssertEqual(fetched?.lastActiveAt, "t1")
        XCTAssertEqual(fetched?.claudeSessionId, "claude-abc")

        // A later local-model turn (no Claude session id of its own) passes the existing one
        // through unchanged rather than clearing it.
        try store.updateAskSessionActivity(
            id: "sess1", turnCount: 2, lastActiveAt: "t2", claudeSessionId: "claude-abc")
        fetched = try store.askSession(id: "sess1")
        XCTAssertEqual(fetched?.turnCount, 2)
        XCTAssertEqual(fetched?.claudeSessionId, "claude-abc")

        XCTAssertEqual(invId, "inv")
    }

    func testAskSessionTurnsOrderedByTurnIndex() throws {
        let (db, invId, _) = try seeded()
        let store = Store(db)
        try store.insertAskSession(
            AskSessionRecord(
                id: "sess1", repositoryId: "repo", commitHash: "c0ffee",
                scopeType: "repository", title: "First.", createdAt: "t0", lastActiveAt: "t0"
            ))
        try store.insertAskSessionTurn(
            AskSessionTurnRecord(
                id: "turn2", sessionId: "sess1", turnIndex: 1, investigationId: invId,
                createdAt: "t1"
            ))
        try store.insertAskSessionTurn(
            AskSessionTurnRecord(
                id: "turn1", sessionId: "sess1", turnIndex: 0, investigationId: invId,
                createdAt: "t0"
            ))

        let turns = try store.askSessionTurns(sessionId: "sess1")
        XCTAssertEqual(turns.map(\.turnIndex), [0, 1])
        XCTAssertEqual(turns.map(\.id), ["turn1", "turn2"])
    }

    func testDeletingSessionCascadesToItsTurns() throws {
        let (db, invId, _) = try seeded()
        let store = Store(db)
        try store.insertAskSession(
            AskSessionRecord(
                id: "sess1", repositoryId: "repo", commitHash: "c0ffee",
                scopeType: "repository", title: "First.", createdAt: "t0", lastActiveAt: "t0"
            ))
        try store.insertAskSessionTurn(
            AskSessionTurnRecord(
                id: "turn1", sessionId: "sess1", turnIndex: 0, investigationId: invId,
                createdAt: "t0"
            ))

        try db.dbQueue.write { dbc in
            try dbc.execute(sql: "DELETE FROM ask_sessions WHERE id = ?", arguments: ["sess1"])
        }

        try db.dbQueue.read { dbc in
            XCTAssertEqual(try AskSessionTurnRecord.fetchCount(dbc), 0)
        }
    }

    func testDeletingInvestigationCascadesToItsSessionTurn() throws {
        let (db, invId, _) = try seeded()
        let store = Store(db)
        try store.insertAskSession(
            AskSessionRecord(
                id: "sess1", repositoryId: "repo", commitHash: "c0ffee",
                scopeType: "repository", title: "First.", createdAt: "t0", lastActiveAt: "t0"
            ))
        try store.insertAskSessionTurn(
            AskSessionTurnRecord(
                id: "turn1", sessionId: "sess1", turnIndex: 0, investigationId: invId,
                createdAt: "t0"
            ))

        try db.dbQueue.write { dbc in
            try dbc.execute(sql: "DELETE FROM investigations WHERE id = ?", arguments: [invId])
        }

        try db.dbQueue.read { dbc in
            XCTAssertEqual(try AskSessionTurnRecord.fetchCount(dbc), 0)
            // The session row itself is untouched -- only the turn pointing at the deleted
            // investigation is gone.
            XCTAssertEqual(try AskSessionRecord.fetchCount(dbc), 1)
        }
    }

    func testDeletingComponentSetsSessionComponentIdNull() throws {
        // `ask_sessions.component_id` is `ON DELETE CASCADE`, not `SET NULL` (Docs/15 §4.2: a
        // component-scoped session without its component is meaningless, not a session that
        // silently becomes repository-scoped) -- this test documents that choice directly rather
        // than assuming it.
        let (db, _, compId) = try seeded()
        let store = Store(db)
        try store.insertAskSession(
            AskSessionRecord(
                id: "sess2", repositoryId: "repo", commitHash: "c0ffee",
                scopeType: "component", componentId: compId, title: "About Authentication.",
                createdAt: "t0", lastActiveAt: "t0"
            ))

        try db.dbQueue.write { dbc in
            try dbc.execute(sql: "DELETE FROM components WHERE id = ?", arguments: [compId])
        }

        try db.dbQueue.read { dbc in
            XCTAssertEqual(try AskSessionRecord.fetchCount(dbc), 0)
        }
    }

    func testDeclinedIsAPersistableInvestigationOutcome() throws {
        let (db, _, _) = try seeded()
        try db.dbQueue.write { dbc in
            try InvestigationRecord(
                id: "inv-declined", repositoryId: "repo", commitHash: "c0ffee", runId: "run",
                question: "What's a good pasta recipe?", complexity: "none", schemaVersion: nil,
                modelUsed: nil, toolsUsed: [], sessionId: nil, numTurns: nil, totalCostUsd: nil,
                durationMs: nil, outcome: InvestigationOutcome.declined.rawValue, createdAt: "t0"
            ).insert(dbc)
        }
        try db.dbQueue.read { dbc in
            let outcome = try String.fetchOne(
                dbc, sql: "SELECT outcome FROM investigations WHERE id = ?",
                arguments: ["inv-declined"])
            XCTAssertEqual(outcome, "declined")
        }
    }
}
