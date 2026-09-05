import XCTest
import GRDB
@testable import OrionCodeIntel

/// Docs/11 M0: `v2_phase2_schema` applies cleanly on top of `v1_phase1_schema`, all six new
/// tables round-trip through their typed records, and the constraints the validation pipeline
/// will lean on (unique component names per *investigation* — not per run, see M6's real-data
/// finding below — and cascading deletes off `investigations`) hold.
final class SemanticSchemaTests: XCTestCase {

    /// A minimal, FK-satisfying Phase 1 chain (repository -> run -> file -> symbol) plus one
    /// investigation row for the Phase 2 tables to hang off.
    private func seeded() throws -> (OrionDatabase, symbolId: String, investigationId: String) {
        let db = try OrionDatabase(inMemory: true)
        try db.dbQueue.write { dbc in
            try RepositoryRecord(
                id: "repo", sourceURL: nil, localPath: "/x", commitHash: "c0ffee",
                languages: ["python"], analysisStatus: .succeeded, createdAt: "t0", updatedAt: "t0"
            ).insert(dbc)
            try AnalysisRunRecord(
                id: "run", repositoryId: "repo", commitHash: "c0ffee", status: "succeeded",
                startedAt: "t0", finishedAt: "t1", orionVersion: "0.1.0", resolver: "none",
                grammarVersions: [:], toolVersions: [:], stageTimings: [:], fileCount: 1,
                symbolCount: 1, relationshipCount: 0, diagnosticCount: 0, error: nil
            ).insert(dbc)
            try FileRecord(
                id: "file", repositoryId: "repo", commitHash: "c0ffee", runId: "run",
                path: "pkg/core.py", language: "python", modulePath: "pkg.core", sha256: "x",
                byteSize: 10, lineCount: 3, isTest: false, isPackageInit: false, parseOk: true
            ).insert(dbc)
            // Not `Make.symbol` — its factory hardcodes repositoryId "r"/commitHash "c" for
            // pure in-memory (no-FK) callers; this test hits a real FK-enforced DB.
            try SymbolRecord(
                id: "sym", repositoryId: "repo", commitHash: "c0ffee", runId: "run",
                fileId: "file", componentId: nil, parentSymbolId: nil, name: "Widget",
                qualifiedName: "pkg.core.Widget", anchor: "pkg/core.py::Widget", kind: "class",
                startLine: 1, startCol: 1, endLine: 3, endCol: 1, startByte: 0, endByte: 30,
                signature: nil, docstring: nil, decorators: [], visibility: "public",
                isExported: true, redirectsTo: nil, epistemicType: "FACT"
            ).insert(dbc)
            try InvestigationRecord(
                id: "inv", repositoryId: "repo", commitHash: "c0ffee", runId: "run",
                question: "phase2_semantic_grouping", complexity: "high",
                schemaVersion: SemanticSchema.currentVersion, modelUsed: "claude-sonnet-5",
                toolsUsed: ["Read", "Grep", "Glob"], sessionId: "sess-1", numTurns: 4,
                totalCostUsd: 0.12, durationMs: 5000, outcome: "verified", createdAt: "t0"
            ).insert(dbc)
        }
        return (db, "sym", "inv")
    }

    func testV2TablesExist() throws {
        let (db, _, _) = try seeded()
        let expected: Set<String> = [
            "components", "component_members", "component_relationships",
            "claims", "evidence", "investigations", "model_revisions",
        ]
        try db.dbQueue.read { dbc in
            let names = try String.fetchSet(dbc, sql: "SELECT name FROM sqlite_master WHERE type = 'table'")
            XCTAssertTrue(expected.isSubset(of: names), "missing: \(expected.subtracting(names))")
        }
    }

    func testPhase1SuiteUnaffected() throws {
        // Same DB Phase 1 tests exercise still has its full v1 shape after v2 is applied.
        let (db, _, _) = try seeded()
        try db.dbQueue.read { dbc in
            XCTAssertEqual(try SymbolRecord.fetchCount(dbc), 1)
            XCTAssertEqual(try RelationshipRecord.fetchCount(dbc), 0)
        }
    }

    func testComponentAndClaimRoundTrip() throws {
        let (db, symbolId, invId) = try seeded()

        try db.dbQueue.write { dbc in
            try ComponentRecord(
                id: "comp1", repositoryId: "repo", commitHash: "c0ffee", runId: "run",
                investigationId: invId, name: "Widgets", description: "Widget stuff.",
                architecturalRole: "core", confidence: 0.8, confidenceTier: "high",
                status: "active", epistemicType: "INTERPRETATION", provenance: "claude_code"
            ).insert(dbc)
            try ComponentRecord(
                id: "comp2", repositoryId: "repo", commitHash: "c0ffee", runId: "run",
                investigationId: invId, name: "Other", description: nil,
                architecturalRole: nil, confidence: 0.6, confidenceTier: "medium",
                status: "active", epistemicType: "INTERPRETATION", provenance: "claude_code"
            ).insert(dbc)
            try ComponentMemberRecord(
                id: "mem1", componentId: "comp1", symbolId: symbolId, confidence: 0.8, role: "core"
            ).insert(dbc)
            try ComponentRelationshipRecord(
                id: "crel1", repositoryId: "repo", commitHash: "c0ffee", runId: "run",
                investigationId: invId, sourceComponentId: "comp1", targetComponentId: "comp2",
                relationshipType: "depends_on", confidence: 0.7, confidenceTier: "medium",
                provenance: "claude_code"
            ).insert(dbc)
            try ClaimRecord(
                id: "claim1", repositoryId: "repo", commitHash: "c0ffee", runId: "run",
                investigationId: invId, subjectRef: "Widgets", predicate: "coordinates",
                objectRef: "pkg/core.py::Widget", statement: "Widget coordinates widget state.",
                claimType: "INTERPRETATION", confidence: 0.8, status: "active",
                createdBy: "claude_code"
            ).insert(dbc)
            try EvidenceRecord(
                id: "ev1", claimId: "claim1", fileId: "file", symbolId: symbolId,
                anchor: "pkg/core.py::Widget", startLine: 1, endLine: 3, evidenceType: "source"
            ).insert(dbc)
            try ModelRevisionRecord(
                id: "rev1", repositoryId: "repo", previousRevision: nil,
                changeSummary: "Initial semantic layer.", triggeringInvestigationId: invId,
                createdAt: "t0"
            ).insert(dbc)
        }

        try db.dbQueue.read { dbc in
            let comp = try XCTUnwrap(ComponentRecord.fetchOne(dbc, key: "comp1"))
            XCTAssertEqual(comp.name, "Widgets")
            XCTAssertEqual(comp.epistemicType, "INTERPRETATION")

            let member = try XCTUnwrap(ComponentMemberRecord.fetchOne(dbc, key: "mem1"))
            XCTAssertEqual(member.symbolId, symbolId)

            let crel = try XCTUnwrap(ComponentRelationshipRecord.fetchOne(dbc, key: "crel1"))
            XCTAssertEqual(crel.relationshipType, "depends_on")

            let claim = try XCTUnwrap(ClaimRecord.fetchOne(dbc, key: "claim1"))
            XCTAssertEqual(claim.claimType, "INTERPRETATION")

            let ev = try XCTUnwrap(EvidenceRecord.fetchOne(dbc, key: "ev1"))
            XCTAssertEqual(ev.startLine, 1)
            XCTAssertEqual(ev.endLine, 3)

            let rev = try XCTUnwrap(ModelRevisionRecord.fetchOne(dbc, key: "rev1"))
            XCTAssertEqual(rev.triggeringInvestigationId, invId)
        }
    }

    func testDuplicateComponentNameWithinSameInvestigationRejected() throws {
        let (db, _, invId) = try seeded()
        try db.dbQueue.write { dbc in
            try ComponentRecord(
                id: "a", repositoryId: "repo", commitHash: "c0ffee", runId: "run",
                investigationId: invId, name: "Widgets", description: nil, architecturalRole: nil,
                confidence: 0.8, confidenceTier: "high", status: "active",
                epistemicType: "INTERPRETATION", provenance: "claude_code"
            ).insert(dbc)
        }
        XCTAssertThrowsError(try db.dbQueue.write { dbc in
            try ComponentRecord(
                id: "b", repositoryId: "repo", commitHash: "c0ffee", runId: "run",
                investigationId: invId, name: "Widgets", description: nil, architecturalRole: nil,
                confidence: 0.5, confidenceTier: "medium", status: "active",
                epistemicType: "INTERPRETATION", provenance: "claude_code"
            ).insert(dbc)
        })
    }

    /// M6 real-data finding: `components` was originally `UNIQUE(run_id, name)`, which broke
    /// the very scenario M6 exists for — three independent live investigations of the same
    /// Starlette run each landed on a component literally named "Middleware Stack" (a
    /// thoroughly reasonable name to reuse), and the second/third ingest hit a raw SQLite
    /// constraint violation instead of persisting. Fixed to `UNIQUE(investigation_id, name)`:
    /// the same name is fine across different investigations of the same run; within-one-
    /// investigation duplicates are still caught (test above), same as before.
    func testSameComponentNameAcrossDifferentInvestigationsAllowed() throws {
        let (db, _, invId1) = try seeded()
        let invId2 = "inv2"
        try db.dbQueue.write { dbc in
            try InvestigationRecord(
                id: invId2, repositoryId: "repo", commitHash: "c0ffee", runId: "run",
                question: "phase2_semantic_grouping", complexity: "high",
                schemaVersion: SemanticSchema.currentVersion, modelUsed: "claude-sonnet-5",
                toolsUsed: ["Read", "Grep", "Glob"], sessionId: "sess-2", numTurns: 30,
                totalCostUsd: 1.5, durationMs: 200_000, outcome: "verified", createdAt: "t1"
            ).insert(dbc)
            try ComponentRecord(
                id: "a", repositoryId: "repo", commitHash: "c0ffee", runId: "run",
                investigationId: invId1, name: "Middleware Stack", description: nil,
                architecturalRole: nil, confidence: 0.8, confidenceTier: "high", status: "active",
                epistemicType: "INTERPRETATION", provenance: "claude_code"
            ).insert(dbc)
            // same name, different investigation, same underlying analysis run -- must succeed
            try ComponentRecord(
                id: "b", repositoryId: "repo", commitHash: "c0ffee", runId: "run",
                investigationId: invId2, name: "Middleware Stack", description: nil,
                architecturalRole: nil, confidence: 0.8, confidenceTier: "high", status: "active",
                epistemicType: "INTERPRETATION", provenance: "claude_code"
            ).insert(dbc)
        }
        try db.dbQueue.read { dbc in
            XCTAssertEqual(try ComponentRecord.fetchCount(dbc), 2)
        }
    }

    func testDeletingInvestigationCascades() throws {
        let (db, symbolId, invId) = try seeded()
        try db.dbQueue.write { dbc in
            try ComponentRecord(
                id: "comp1", repositoryId: "repo", commitHash: "c0ffee", runId: "run",
                investigationId: invId, name: "Widgets", description: nil, architecturalRole: nil,
                confidence: 0.8, confidenceTier: "high", status: "active",
                epistemicType: "INTERPRETATION", provenance: "claude_code"
            ).insert(dbc)
            try ComponentMemberRecord(
                id: "mem1", componentId: "comp1", symbolId: symbolId, confidence: 0.8, role: "core"
            ).insert(dbc)
            try ClaimRecord(
                id: "claim1", repositoryId: "repo", commitHash: "c0ffee", runId: "run",
                investigationId: invId, subjectRef: "Widgets", predicate: nil, objectRef: nil,
                statement: "x", claimType: "INTERPRETATION", confidence: 0.8, status: "active",
                createdBy: "claude_code"
            ).insert(dbc)
            try dbc.execute(sql: "DELETE FROM investigations WHERE id = ?", arguments: [invId])
        }
        try db.dbQueue.read { dbc in
            XCTAssertEqual(try ComponentRecord.fetchCount(dbc), 0)
            XCTAssertEqual(try ComponentMemberRecord.fetchCount(dbc), 0)
            XCTAssertEqual(try ClaimRecord.fetchCount(dbc), 0)
        }
    }
}
