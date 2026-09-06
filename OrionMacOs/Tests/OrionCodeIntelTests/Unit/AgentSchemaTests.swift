import XCTest
import GRDB
@testable import OrionCodeIntel

/// Docs/12 M1/M2: `v3_phase3_schema` applies cleanly on top of `v1_phase1_schema`/
/// `v2_phase2_schema`, `routing_decisions` (M1) and `agent_tool_calls` (M2) round-trip through
/// their typed records, and deleting the owning investigation cascades to both — same shape as
/// `SemanticSchemaTests` for Phase 2's tables.
final class AgentSchemaTests: XCTestCase {

    /// A minimal, FK-satisfying chain (repository -> run -> investigation) for
    /// `routing_decisions`/`agent_tool_calls` to hang off.
    private func seeded() throws -> (OrionDatabase, investigationId: String) {
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
        }
        return (db, "inv")
    }

    func testV3TableExists() throws {
        let (db, _) = try seeded()
        try db.dbQueue.read { dbc in
            let names = try String.fetchSet(
                dbc, sql: "SELECT name FROM sqlite_master WHERE type = 'table'")
            XCTAssertTrue(names.contains("routing_decisions"))
            XCTAssertTrue(names.contains("agent_tool_calls"))
        }
    }

    func testAgentToolCallRoundTrip() throws {
        let (db, invId) = try seeded()
        let store = Store(db)

        try store.insertAgentToolCall(
            AgentToolCallRecord(
                id: "tc1", investigationId: invId, turnIndex: 1, toolName: "lookup_symbol",
                arguments: #"{"query":"Widget"}"#,
                resultSummary: "pkg/a.py::Widget (class) — pkg/a.py:3-5", latencyMs: 12.5,
                createdAt: "t0"
            ))

        let calls = try store.agentToolCalls(investigationId: invId)
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.toolName, "lookup_symbol")
        XCTAssertEqual(calls.first?.turnIndex, 1)
        XCTAssertEqual(calls.first?.latencyMs, 12.5)
    }

    func testAgentToolCallsOrderedByTurnIndex() throws {
        let (db, invId) = try seeded()
        let store = Store(db)
        try store.insertAgentToolCall(
            AgentToolCallRecord(
                id: "tc2", investigationId: invId, turnIndex: 2, toolName: "callees",
                arguments: "{}", resultSummary: "x", latencyMs: nil, createdAt: "t0"
            ))
        try store.insertAgentToolCall(
            AgentToolCallRecord(
                id: "tc1", investigationId: invId, turnIndex: 1, toolName: "lookup_symbol",
                arguments: "{}", resultSummary: "y", latencyMs: nil, createdAt: "t0"
            ))

        let calls = try store.agentToolCalls(investigationId: invId)
        XCTAssertEqual(calls.map(\.turnIndex), [1, 2])
    }

    func testDeletingInvestigationCascadesToAgentToolCalls() throws {
        let (db, invId) = try seeded()
        let store = Store(db)
        try store.insertAgentToolCall(
            AgentToolCallRecord(
                id: "tc1", investigationId: invId, turnIndex: 1, toolName: "lookup_symbol",
                arguments: "{}", resultSummary: "x", latencyMs: nil, createdAt: "t0"
            ))

        try db.dbQueue.write { dbc in
            try dbc.execute(sql: "DELETE FROM investigations WHERE id = ?", arguments: [invId])
        }

        try db.dbQueue.read { dbc in
            XCTAssertEqual(try AgentToolCallRecord.fetchCount(dbc), 0)
        }
    }

    func testRoutingDecisionRoundTrip() throws {
        let (db, invId) = try seeded()
        let store = Store(db)

        try store.insertRoutingDecision(
            RoutingDecisionRecord(
                id: "rd1", investigationId: invId, depthLevel: 1, method: "heuristic",
                confidence: "high",
                rationale: "Matched explicit depth-1 rule for \"component_purpose\".",
                createdAt: "t0"
            ))

        let decisions = try store.routingDecisions(investigationId: invId)
        XCTAssertEqual(decisions.count, 1)
        XCTAssertEqual(decisions.first?.depthLevel, 1)
        XCTAssertEqual(decisions.first?.method, "heuristic")
        XCTAssertEqual(decisions.first?.confidence, "high")
    }

    func testDeletingInvestigationCascadesToRoutingDecisions() throws {
        let (db, invId) = try seeded()
        let store = Store(db)
        try store.insertRoutingDecision(
            RoutingDecisionRecord(
                id: "rd1", investigationId: invId, depthLevel: 2, method: "model",
                confidence: "medium", rationale: "x", createdAt: "t0"
            ))

        try db.dbQueue.write { dbc in
            try dbc.execute(sql: "DELETE FROM investigations WHERE id = ?", arguments: [invId])
        }

        try db.dbQueue.read { dbc in
            XCTAssertEqual(try RoutingDecisionRecord.fetchCount(dbc), 0)
        }
    }
}
