import XCTest
import GRDB
@testable import OrionCodeIntel

/// Docs/16 M0: `v5_phase6_schema` applies cleanly on top of `v1_phase1_schema`/
/// `v2_phase2_schema`/`v3_phase3_schema`/`v4_phase5_schema`, `model_revisions.revision_number`
/// round-trips (defaulting to `1` for every pre-Phase-6 construction site) and
/// `model_revision_entries` round-trips through its typed record, and both cascade directions
/// hold (`model_revision_id` -> `CASCADE`, `related_claim_id` -> `SET NULL`) — same shape as
/// `AskSessionSchemaTests`/`SemanticSchemaTests` for Phase 5/2's own tables. `RevisionDiffer`
/// itself (Docs/16 §4) is not built yet — this file only exercises the schema and bare `Store`
/// CRUD M0 actually adds.
final class ModelRevisionSchemaTests: XCTestCase {

    /// A minimal, FK-satisfying chain (repository -> run -> investigation -> claim) for
    /// `model_revisions`/`model_revision_entries` to hang off.
    private func seeded() throws -> (db: OrionDatabase, investigationId: String, claimId: String) {
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
                question: "phase2_semantic_grouping", complexity: "high",
                schemaVersion: nil, modelUsed: "claude-sonnet-5",
                toolsUsed: [], sessionId: nil, numTurns: nil, totalCostUsd: nil,
                durationMs: nil, outcome: "verified", createdAt: "t0"
            ).insert(dbc)
            try ClaimRecord(
                id: "claim1", repositoryId: "repo", commitHash: "c0ffee", runId: "run",
                investigationId: "inv", subjectRef: "pkg/core.py::Widget", predicate: nil,
                objectRef: nil, statement: "Widget coordinates widget state.",
                claimType: "INTERPRETATION", confidence: 0.8, status: "active",
                createdBy: "claude_code"
            ).insert(dbc)
        }
        return (db, "inv", "claim1")
    }

    func testV5TableExists() throws {
        let (db, _, _) = try seeded()
        try db.dbQueue.read { dbc in
            let names = try String.fetchSet(
                dbc, sql: "SELECT name FROM sqlite_master WHERE type = 'table'")
            XCTAssertTrue(names.contains("model_revision_entries"))
        }
    }

    func testPhase1Through5SuiteUnaffected() throws {
        // Same DB Phase 1-5 tests exercise still has its full v1-v4 shape after v5 is applied.
        let (db, invId, claimId) = try seeded()
        try db.dbQueue.read { dbc in
            XCTAssertEqual(try InvestigationRecord.fetchCount(dbc), 1)
            XCTAssertEqual(try ClaimRecord.fetchCount(dbc), 1)
        }
        XCTAssertEqual(invId, "inv")
        XCTAssertEqual(claimId, "claim1")
    }

    func testModelRevisionDefaultsRevisionNumberToOne() throws {
        // Every pre-Phase-6 construction site (SemanticImporter's two writers, SemanticSchemaTests)
        // omits `revisionNumber` entirely -- confirms the default keeps that compiling and behaving
        // unchanged.
        let (db, invId, _) = try seeded()
        let store = Store(db)
        try store.insertModelRevision(
            ModelRevisionRecord(
                id: "rev1", repositoryId: "repo", previousRevision: nil,
                changeSummary: "Initial semantic layer.", triggeringInvestigationId: invId,
                createdAt: "t0"
            ))

        let fetched = try store.latestModelRevision(repositoryId: "repo")
        XCTAssertEqual(fetched?.revisionNumber, 1)
    }

    func testModelRevisionsListedNewestFirstByRevisionNumber() throws {
        let (db, invId, _) = try seeded()
        let store = Store(db)
        try store.insertModelRevision(
            ModelRevisionRecord(
                id: "rev1", repositoryId: "repo", previousRevision: nil,
                changeSummary: "First.", triggeringInvestigationId: invId, createdAt: "t0",
                revisionNumber: 1
            ))
        try store.insertModelRevision(
            ModelRevisionRecord(
                id: "rev2", repositoryId: "repo", previousRevision: "rev1",
                changeSummary: "Second.", triggeringInvestigationId: invId, createdAt: "t1",
                revisionNumber: 2
            ))

        let listed = try store.modelRevisions(repositoryId: "repo")
        XCTAssertEqual(listed.map(\.id), ["rev2", "rev1"])
    }

    func testModelRevisionEntryRoundTrip() throws {
        let (db, invId, claimId) = try seeded()
        let store = Store(db)
        try store.insertModelRevision(
            ModelRevisionRecord(
                id: "rev1", repositoryId: "repo", previousRevision: nil,
                changeSummary: "1 change: 1 claim added.", triggeringInvestigationId: invId,
                createdAt: "t0", revisionNumber: 1
            ))

        try store.insertModelRevisionEntries([
            ModelRevisionEntryRecord(
                id: "entry1", modelRevisionId: "rev1",
                entityType: ModelRevisionEntityType.claim.rawValue,
                changeType: ModelRevisionChangeType.added.rawValue,
                subjectLabel: "Widget coordinates widget state.",
                previousStateJson: nil, newStateJson: "{\"statement\":\"...\"}",
                reason: "New claim about pkg/core.py::Widget: \"Widget coordinates widget state.\".",
                confidenceTier: "high", relatedClaimId: claimId, createdAt: "t0"
            )
        ])

        let fetched = try store.modelRevisionEntries(modelRevisionId: "rev1")
        XCTAssertEqual(fetched.count, 1)
        XCTAssertEqual(fetched[0].entityType, "claim")
        XCTAssertEqual(fetched[0].changeType, "added")
        XCTAssertEqual(fetched[0].relatedClaimId, claimId)
        XCTAssertNil(fetched[0].previousStateJson)
    }

    func testInsertModelRevisionEntriesIsBulkAndSkipsEmpty() throws {
        let (db, invId, _) = try seeded()
        let store = Store(db)
        try store.insertModelRevision(
            ModelRevisionRecord(
                id: "rev1", repositoryId: "repo", previousRevision: nil,
                changeSummary: "2 changes.", triggeringInvestigationId: invId, createdAt: "t0",
                revisionNumber: 1
            ))

        try store.insertModelRevisionEntries([])  // no-op, must not throw
        try store.insertModelRevisionEntries([
            ModelRevisionEntryRecord(
                id: "entryA", modelRevisionId: "rev1", entityType: "component",
                changeType: "added", subjectLabel: "Routing", previousStateJson: nil,
                newStateJson: nil, reason: "New component 'Routing' identified.",
                confidenceTier: "high", relatedClaimId: nil, createdAt: "t0"
            ),
            ModelRevisionEntryRecord(
                id: "entryB", modelRevisionId: "rev1", entityType: "component",
                changeType: "removed", subjectLabel: "Legacy", previousStateJson: nil,
                newStateJson: nil, reason: "Component 'Legacy' no longer appears.",
                confidenceTier: nil, relatedClaimId: nil, createdAt: "t0"
            )
        ])

        let fetched = try store.modelRevisionEntries(modelRevisionId: "rev1")
        XCTAssertEqual(Set(fetched.map(\.id)), ["entryA", "entryB"])
    }

    func testDeletingModelRevisionCascadesToItsEntries() throws {
        let (db, invId, _) = try seeded()
        let store = Store(db)
        try store.insertModelRevision(
            ModelRevisionRecord(
                id: "rev1", repositoryId: "repo", previousRevision: nil,
                changeSummary: "1 change.", triggeringInvestigationId: invId, createdAt: "t0",
                revisionNumber: 1
            ))
        try store.insertModelRevisionEntries([
            ModelRevisionEntryRecord(
                id: "entry1", modelRevisionId: "rev1", entityType: "component",
                changeType: "added", subjectLabel: "Routing", previousStateJson: nil,
                newStateJson: nil, reason: "New component 'Routing' identified.",
                confidenceTier: "high", relatedClaimId: nil, createdAt: "t0"
            )
        ])

        try db.dbQueue.write { dbc in
            try dbc.execute(sql: "DELETE FROM model_revisions WHERE id = ?", arguments: ["rev1"])
        }

        try db.dbQueue.read { dbc in
            XCTAssertEqual(try ModelRevisionEntryRecord.fetchCount(dbc), 0)
        }
    }

    func testDeletingRelatedClaimSetsEntryFieldNullNotCascade() throws {
        // §5's "addressed" hedge link (Docs/16 §2) must survive its claim's own later deletion --
        // the entry and its reason text stay meaningful even once the claim it once pointed at is
        // gone, unlike model_revision_id's own CASCADE relationship.
        let (db, invId, claimId) = try seeded()
        let store = Store(db)
        try store.insertModelRevision(
            ModelRevisionRecord(
                id: "rev1", repositoryId: "repo", previousRevision: nil,
                changeSummary: "1 change.", triggeringInvestigationId: invId, createdAt: "t0",
                revisionNumber: 1
            ))
        try store.insertModelRevisionEntries([
            ModelRevisionEntryRecord(
                id: "entry1", modelRevisionId: "rev1", entityType: "uncertainty",
                changeType: "addressed", subjectLabel: "Whether X or Y.", previousStateJson: nil,
                newStateJson: nil,
                reason: "Possibly addressed by a new claim: \"Widget coordinates widget state.\"",
                confidenceTier: nil, relatedClaimId: claimId, createdAt: "t0"
            )
        ])

        try db.dbQueue.write { dbc in
            try dbc.execute(sql: "DELETE FROM claims WHERE id = ?", arguments: [claimId])
        }

        let fetched = try store.modelRevisionEntries(modelRevisionId: "rev1")
        XCTAssertEqual(fetched.count, 1)
        XCTAssertNil(fetched[0].relatedClaimId)
        XCTAssertEqual(fetched[0].changeType, "addressed")
    }
}
