import XCTest
@testable import OrionCodeIntel

/// Docs/16 M2: `RevisionDiffer` against fixture data — no real analyzed repo, no `claude` CLI
/// call, matching this codebase's own established fixture-driven pattern for schema-adjacent
/// logic (`SemanticImporterTests`, `ComponentDetailLoaderTests`). `RevisionDiffer` is not yet
/// wired into `SemanticImporter` (that's M4) — every test here calls it directly.
final class RevisionDifferTests: XCTestCase {

    // MARK: - Fixture helpers

    private func seededRepository() throws -> (db: OrionDatabase, store: Store) {
        let db = try OrionDatabase(inMemory: true)
        let store = Store(db)
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
            try FileRecord(
                id: "file1", repositoryId: "repo", commitHash: "c0ffee", runId: "run",
                path: "pkg/mod.py", language: "python", modulePath: "pkg.mod", sha256: "x",
                byteSize: 10, lineCount: 10, isTest: false, isPackageInit: false, parseOk: true
            ).insert(dbc)
        }
        return (db, store)
    }

    /// Every symbol lives in the same fixture file; only its anchor and id are ever inspected by
    /// `RevisionDiffer`.
    private func insertSymbol(_ db: OrionDatabase, id: String, anchor: String) throws {
        try db.dbQueue.write { dbc in
            try SymbolRecord(
                id: id, repositoryId: "repo", commitHash: "c0ffee", runId: "run", fileId: "file1",
                componentId: nil, parentSymbolId: nil, name: id, qualifiedName: id, anchor: anchor,
                kind: "function", startLine: 1, startCol: 0, endLine: 2, endCol: 0, startByte: 0,
                endByte: 10, signature: nil, docstring: nil, decorators: [], visibility: "public",
                isExported: true, redirectsTo: nil, epistemicType: "FACT"
            ).insert(dbc)
        }
    }

    private func insertInvestigation(
        _ store: Store, id: String, question: String, createdAt: String
    ) throws {
        try store.insertInvestigation(InvestigationRecord(
            id: id, repositoryId: "repo", commitHash: "c0ffee", runId: "run", question: question,
            complexity: "high", outcome: "verified", createdAt: createdAt
        ))
    }

    @discardableResult
    private func insertComponent(
        _ store: Store, id: String, investigationId: String, name: String,
        description: String? = "A component.", role: String? = "core",
        memberSymbolIds: [String], confidenceTier: String = "high"
    ) throws -> ComponentRecord {
        let record = ComponentRecord(
            id: id, repositoryId: "repo", commitHash: "c0ffee", runId: "run",
            investigationId: investigationId, name: name, description: description,
            architecturalRole: role, confidence: 0.9, confidenceTier: confidenceTier,
            status: "active", epistemicType: "INTERPRETATION", provenance: "claude_code"
        )
        try store.insertComponents([record])
        try store.insertComponentMembers(memberSymbolIds.map {
            ComponentMemberRecord(id: "\(id)-\($0)", componentId: id, symbolId: $0, confidence: 0.9, role: "core")
        })
        return record
    }

    private func insertRelationship(
        _ store: Store, id: String, investigationId: String, sourceId: String, targetId: String,
        type: String = "depends_on", confidenceTier: String = "high"
    ) throws {
        try store.insertComponentRelationships([ComponentRelationshipRecord(
            id: id, repositoryId: "repo", commitHash: "c0ffee", runId: "run",
            investigationId: investigationId, sourceComponentId: sourceId, targetComponentId: targetId,
            relationshipType: type, confidence: 0.9, confidenceTier: confidenceTier,
            provenance: "claude_code"
        )])
    }

    private func insertClaim(
        _ store: Store, id: String, investigationId: String, statement: String,
        claimType: String = "INTERPRETATION", confidence: Double = 0.9,
        subjectRef: String?, evidenceAnchors: [String]
    ) throws {
        try store.insertClaims([ClaimRecord(
            id: id, repositoryId: "repo", commitHash: "c0ffee", runId: "run",
            investigationId: investigationId, subjectRef: subjectRef, predicate: nil, objectRef: nil,
            statement: statement, claimType: claimType, confidence: confidence, status: "active",
            createdBy: "claude_code"
        )])
        try store.insertEvidence(evidenceAnchors.enumerated().map { i, anchor in
            EvidenceRecord(
                id: "\(id)-ev\(i)", claimId: id, fileId: "file1", symbolId: nil, anchor: anchor,
                startLine: 1, endLine: 2, evidenceType: "source"
            )
        })
    }

    private let architectureQuestion = InvestigationRecord.architectureQuestionMarker

    // MARK: - First investigation ever

    func testFirstInvestigationProducesNoEntries() throws {
        let (db, store) = try seededRepository()
        try insertSymbol(db, id: "sym1", anchor: "pkg/mod.py::routing")
        try insertInvestigation(store, id: "inv1", question: architectureQuestion, createdAt: "t0")
        try insertComponent(store, id: "c1", investigationId: "inv1", name: "Routing", memberSymbolIds: ["sym1"])

        let result = try RevisionDiffer.diff(store: store, repositoryId: "repo", newInvestigationId: "inv1")
        XCTAssertTrue(result.isEmpty)
    }

    // MARK: - Components: added / removed / modified

    func testAddedRemovedAndModifiedComponents() throws {
        let (db, store) = try seededRepository()
        try insertSymbol(db, id: "router", anchor: "pkg/mod.py::Router")
        try insertSymbol(db, id: "auth", anchor: "pkg/mod.py::Auth")
        try insertSymbol(db, id: "old", anchor: "pkg/mod.py::Old")

        try insertInvestigation(store, id: "inv1", question: architectureQuestion, createdAt: "t0")
        try insertComponent(store, id: "routing1", investigationId: "inv1", name: "Routing", memberSymbolIds: ["router"])
        try insertComponent(store, id: "legacy1", investigationId: "inv1", name: "Legacy", memberSymbolIds: ["old"])

        try insertInvestigation(store, id: "inv2", question: architectureQuestion, createdAt: "t1")
        // Routing keeps its old member and gains a new one -> modified (membership changed).
        try insertComponent(
            store, id: "routing2", investigationId: "inv2", name: "Routing",
            memberSymbolIds: ["router", "auth"])
        // Legacy is gone.
        // Middleware is new.
        try insertComponent(store, id: "mw2", investigationId: "inv2", name: "Middleware", memberSymbolIds: ["auth"])

        let result = try RevisionDiffer.diff(store: store, repositoryId: "repo", newInvestigationId: "inv2")
        let byLabelAndType = Dictionary(
            uniqueKeysWithValues: result.entries.map { ("\($0.subjectLabel)/\($0.changeType.rawValue)", $0) })

        let added = try XCTUnwrap(byLabelAndType["Middleware/added"])
        XCTAssertEqual(added.entityType, .component)
        XCTAssertNil(added.previousStateJson)
        XCTAssertTrue(added.reason.contains("New component 'Middleware'"))

        let removed = try XCTUnwrap(byLabelAndType["Legacy/removed"])
        XCTAssertEqual(removed.entityType, .component)
        XCTAssertNil(removed.newStateJson)
        XCTAssertTrue(removed.reason.contains("no longer appears"))

        let modified = try XCTUnwrap(byLabelAndType["Routing/modified"])
        XCTAssertEqual(modified.entityType, .component)
        XCTAssertTrue(modified.reason.contains("membership changed: +1 / -0"))

        XCTAssertEqual(result.entries.count, 3)
    }

    func testUnchangedComponentProducesNoEntry() throws {
        let (db, store) = try seededRepository()
        try insertSymbol(db, id: "router", anchor: "pkg/mod.py::Router")
        try insertInvestigation(store, id: "inv1", question: architectureQuestion, createdAt: "t0")
        try insertComponent(store, id: "routing1", investigationId: "inv1", name: "Routing", memberSymbolIds: ["router"])
        try insertInvestigation(store, id: "inv2", question: architectureQuestion, createdAt: "t1")
        try insertComponent(store, id: "routing2", investigationId: "inv2", name: "Routing", memberSymbolIds: ["router"])

        let result = try RevisionDiffer.diff(store: store, repositoryId: "repo", newInvestigationId: "inv2")
        XCTAssertTrue(result.isEmpty)
    }

    // MARK: - Component relationships: the Docs/05 Stage 6 multi-hop shape

    func testAddedAndRemovedComponentRelationshipsProduceTheStage6Shape() throws {
        let (db, store) = try seededRepository()
        for (id, anchor) in [
            ("auth", "pkg/mod.py::AuthService"), ("persist", "pkg/mod.py::Persistence"),
            ("sess", "pkg/mod.py::SessionManager"), ("store_", "pkg/mod.py::SessionStore"),
            ("keychain", "pkg/mod.py::Keychain")
        ] {
            try insertSymbol(db, id: id, anchor: anchor)
        }

        try insertInvestigation(store, id: "inv1", question: architectureQuestion, createdAt: "t0")
        try insertComponent(store, id: "auth1", investigationId: "inv1", name: "AuthService", memberSymbolIds: ["auth"])
        try insertComponent(store, id: "persist1", investigationId: "inv1", name: "Persistence", memberSymbolIds: ["persist"])
        try insertComponent(store, id: "sess1", investigationId: "inv1", name: "SessionManager", memberSymbolIds: ["sess"])
        try insertComponent(store, id: "store1", investigationId: "inv1", name: "SessionStore", memberSymbolIds: ["store_"])
        try insertComponent(store, id: "key1", investigationId: "inv1", name: "Keychain", memberSymbolIds: ["keychain"])
        try insertRelationship(store, id: "rel1", investigationId: "inv1", sourceId: "auth1", targetId: "persist1")

        try insertInvestigation(store, id: "inv2", question: architectureQuestion, createdAt: "t1")
        // Same five components, unchanged -- isolates this test to relationship diffing only.
        try insertComponent(store, id: "auth2", investigationId: "inv2", name: "AuthService", memberSymbolIds: ["auth"])
        try insertComponent(store, id: "persist2", investigationId: "inv2", name: "Persistence", memberSymbolIds: ["persist"])
        try insertComponent(store, id: "sess2", investigationId: "inv2", name: "SessionManager", memberSymbolIds: ["sess"])
        try insertComponent(store, id: "store2", investigationId: "inv2", name: "SessionStore", memberSymbolIds: ["store_"])
        try insertComponent(store, id: "key2", investigationId: "inv2", name: "Keychain", memberSymbolIds: ["keychain"])
        // AuthService -> Persistence is gone; replaced by a three-hop chain through SessionManager.
        try insertRelationship(store, id: "rel2a", investigationId: "inv2", sourceId: "auth2", targetId: "sess2")
        try insertRelationship(store, id: "rel2b", investigationId: "inv2", sourceId: "sess2", targetId: "store2")
        try insertRelationship(store, id: "rel2c", investigationId: "inv2", sourceId: "store2", targetId: "key2")

        let result = try RevisionDiffer.diff(store: store, repositoryId: "repo", newInvestigationId: "inv2")
        let relationshipEntries = result.entries.filter { $0.entityType == .componentRelationship }
        XCTAssertEqual(relationshipEntries.count, 4)

        let removed = relationshipEntries.filter { $0.changeType == .removed }
        XCTAssertEqual(removed.map(\.subjectLabel), ["AuthService -> Persistence"])

        let added = Set(relationshipEntries.filter { $0.changeType == .added }.map(\.subjectLabel))
        XCTAssertEqual(added, [
            "AuthService -> SessionManager", "SessionManager -> SessionStore", "SessionStore -> Keychain"
        ])

        // No component-level entries at all -- the five components are byte-identical across
        // both investigations, isolating this as a pure relationship change.
        XCTAssertTrue(result.entries.allSatisfy { $0.entityType == .componentRelationship })
    }

    // MARK: - Claims

    func testNewClaimWithNoPriorMatchIsAdded() throws {
        let (db, store) = try seededRepository()
        try insertSymbol(db, id: "a", anchor: "pkg/mod.py::A")
        try insertSymbol(db, id: "b", anchor: "pkg/mod.py::B")
        try insertInvestigation(store, id: "inv1", question: "What does A do?", createdAt: "t0")
        try insertClaim(
            store, id: "claim1", investigationId: "inv1", statement: "A does something.",
            subjectRef: "pkg/mod.py::A", evidenceAnchors: ["pkg/mod.py::A"])

        try insertInvestigation(store, id: "inv2", question: "What does B do?", createdAt: "t1")
        try insertClaim(
            store, id: "claim2", investigationId: "inv2", statement: "B does something else.",
            subjectRef: "pkg/mod.py::B", evidenceAnchors: ["pkg/mod.py::B"])

        let result = try RevisionDiffer.diff(store: store, repositoryId: "repo", newInvestigationId: "inv2")
        XCTAssertEqual(result.entries.count, 1)
        let entry = try XCTUnwrap(result.entries.first)
        XCTAssertEqual(entry.entityType, .claim)
        XCTAssertEqual(entry.changeType, .added)
        XCTAssertNil(entry.previousStateJson)
        XCTAssertTrue(entry.reason.contains("New claim about pkg/mod.py::B"))
        XCTAssertTrue(result.diagnostics.isEmpty)
    }

    func testRefinedClaimWithExtraEvidenceIsModified() throws {
        let (db, store) = try seededRepository()
        try insertSymbol(db, id: "a", anchor: "pkg/mod.py::A")
        try insertSymbol(db, id: "b", anchor: "pkg/mod.py::B")
        try insertInvestigation(store, id: "inv1", question: architectureQuestion, createdAt: "t0")
        try insertClaim(
            store, id: "claim1", investigationId: "inv1", statement: "A coordinates state.",
            subjectRef: "pkg/mod.py::A", evidenceAnchors: ["pkg/mod.py::A"])

        try insertInvestigation(store, id: "inv2", question: "Tell me more about A.", createdAt: "t1")
        try insertClaim(
            store, id: "claim2", investigationId: "inv2", statement: "A coordinates state.",
            subjectRef: "pkg/mod.py::A", evidenceAnchors: ["pkg/mod.py::A", "pkg/mod.py::B"])

        let result = try RevisionDiffer.diff(store: store, repositoryId: "repo", newInvestigationId: "inv2")
        XCTAssertEqual(result.entries.count, 1)
        let entry = try XCTUnwrap(result.entries.first)
        XCTAssertEqual(entry.entityType, .claim)
        XCTAssertEqual(entry.changeType, .modified)
        // Points at the current, still-persisted claim ("claim2"), not the superseded one --
        // Docs/16 M5's correction so the app's own CONTRADICTED-claim cross-reference can find
        // this entry starting from whichever claim it's actually looking at.
        XCTAssertEqual(entry.relatedClaimId, "claim2")
        XCTAssertTrue(entry.reason.contains("evidence now includes pkg/mod.py::B"))
    }

    func testReversedClaimWhenStructuralVerdictsDisagree() throws {
        let (db, store) = try seededRepository()
        try insertSymbol(db, id: "a", anchor: "pkg/mod.py::A")
        try insertInvestigation(store, id: "inv1", question: architectureQuestion, createdAt: "t0")
        try insertClaim(
            store, id: "claim1", investigationId: "inv1", statement: "A is safe.",
            claimType: "INTERPRETATION", subjectRef: "pkg/mod.py::A", evidenceAnchors: ["pkg/mod.py::A"])

        try insertInvestigation(store, id: "inv2", question: "Is A safe?", createdAt: "t1")
        try insertClaim(
            store, id: "claim2", investigationId: "inv2", statement: "A is not safe after all.",
            claimType: "CONTRADICTED", subjectRef: "pkg/mod.py::A", evidenceAnchors: ["pkg/mod.py::A"])

        let result = try RevisionDiffer.diff(store: store, repositoryId: "repo", newInvestigationId: "inv2")
        XCTAssertEqual(result.entries.count, 1)
        let entry = try XCTUnwrap(result.entries.first)
        XCTAssertEqual(entry.changeType, .reversed)
        // Points at the current, still-persisted (now-contradicted) claim ("claim2") -- the one
        // the app would actually be displaying -- not the superseded "claim1".
        XCTAssertEqual(entry.relatedClaimId, "claim2")
        XCTAssertTrue(entry.reason.contains("previously confirmed, now contradicted"))
    }

    func testAmbiguousClaimMatchLogsDiagnosticAndPicksEarliestHighestScoring() throws {
        let (db, store) = try seededRepository()
        for (id, anchor) in [("a", "pkg/mod.py::A"), ("b", "pkg/mod.py::B"), ("c", "pkg/mod.py::C")] {
            try insertSymbol(db, id: id, anchor: anchor)
        }
        try insertInvestigation(store, id: "inv1", question: "Q1", createdAt: "t0")
        try insertClaim(
            store, id: "claim1", investigationId: "inv1", statement: "AB claim.",
            subjectRef: "pkg/mod.py::A", evidenceAnchors: ["pkg/mod.py::A", "pkg/mod.py::B"])
        try insertInvestigation(store, id: "inv2", question: "Q2", createdAt: "t1")
        try insertClaim(
            store, id: "claim2", investigationId: "inv2", statement: "AC claim.",
            subjectRef: "pkg/mod.py::A", evidenceAnchors: ["pkg/mod.py::A", "pkg/mod.py::C"])

        // New claim overlaps both prior claims equally: jaccard({A,B},{A,B,C}) = 2/3,
        // jaccard({A,C},{A,B,C}) = 2/3 -- a genuine tie, both above threshold.
        try insertInvestigation(store, id: "inv3", question: "Q3", createdAt: "t2")
        try insertClaim(
            store, id: "claim3", investigationId: "inv3", statement: "ABC claim.",
            subjectRef: "pkg/mod.py::A",
            evidenceAnchors: ["pkg/mod.py::A", "pkg/mod.py::B", "pkg/mod.py::C"])

        let result = try RevisionDiffer.diff(store: store, repositoryId: "repo", newInvestigationId: "inv3")
        XCTAssertEqual(result.diagnostics.count, 1)
        XCTAssertEqual(result.diagnostics[0].code, "CLAIM_DIFF_AMBIGUOUS")

        // Exactly one entry, not one per ambiguous candidate -- ambiguity is logged, not fanned out.
        XCTAssertEqual(result.entries.count, 1)
        // The tie-break itself still keeps the earliest-created investigation's claim (claim1,
        // from inv1 @ t0) as the *match* (asserted via the diagnostic above); the entry's own
        // `relatedClaimId` points at the current claim (claim3) regardless of which historical
        // claim won the tie, per Docs/16 M5's correction.
        XCTAssertEqual(result.entries[0].relatedClaimId, "claim3")
    }

    func testUnchangedClaimProducesNoEntry() throws {
        let (db, store) = try seededRepository()
        try insertSymbol(db, id: "a", anchor: "pkg/mod.py::A")
        try insertInvestigation(store, id: "inv1", question: architectureQuestion, createdAt: "t0")
        try insertClaim(
            store, id: "claim1", investigationId: "inv1", statement: "A coordinates state.",
            subjectRef: "pkg/mod.py::A", evidenceAnchors: ["pkg/mod.py::A"])
        try insertInvestigation(store, id: "inv2", question: "Tell me about A again.", createdAt: "t1")
        try insertClaim(
            store, id: "claim2", investigationId: "inv2", statement: "A coordinates state.",
            subjectRef: "pkg/mod.py::A", evidenceAnchors: ["pkg/mod.py::A"])

        let result = try RevisionDiffer.diff(store: store, repositoryId: "repo", newInvestigationId: "inv2")
        XCTAssertTrue(result.isEmpty)
    }

    func testUnknownClaimsAreExcludedFromClaimDiffingButHandledByUncertaintyDiffing() throws {
        let (db, store) = try seededRepository()
        try insertSymbol(db, id: "a", anchor: "pkg/mod.py::A")
        try insertInvestigation(store, id: "inv1", question: architectureQuestion, createdAt: "t0")
        try insertInvestigation(store, id: "inv2", question: "A follow-up.", createdAt: "t1")
        // An uncertainties[]-derived claim: UNKNOWN, no evidence (Docs/11's own design).
        try insertClaim(
            store, id: "claim2", investigationId: "inv2", statement: "Whether X or Y is unclear.",
            claimType: "UNKNOWN", subjectRef: nil, evidenceAnchors: [])

        let result = try RevisionDiffer.diff(store: store, repositoryId: "repo", newInvestigationId: "inv2")
        // §4.3's claim diffing never touches it (no `.claim`-type entry)...
        XCTAssertTrue(result.entries.allSatisfy { $0.entityType != .claim })
        // ...but §5's uncertainty diffing (M3) does -- it's a brand-new open question with no
        // prior question-kind investigation to compare against, so it's `.added`, not dropped.
        XCTAssertEqual(result.entries.count, 1)
        XCTAssertEqual(result.entries[0].entityType, .uncertainty)
        XCTAssertEqual(result.entries[0].changeType, .added)
    }

    // MARK: - Kind determination

    func testNonArchitectureInvestigationNeverDiffsComponentsOrRelationships() throws {
        let (db, store) = try seededRepository()
        try insertSymbol(db, id: "router", anchor: "pkg/mod.py::Router")
        try insertInvestigation(store, id: "inv1", question: architectureQuestion, createdAt: "t0")
        try insertComponent(store, id: "routing1", investigationId: "inv1", name: "Routing", memberSymbolIds: ["router"])

        // inv2 is a plain Ask investigation -- even though a components row happens to exist
        // (which real ingestAnswer() never actually does, Docs/12 "What Phase 3 is not"), the
        // differ must key its architecture-vs-question decision off the investigation's own
        // `question` column, never off what rows happen to exist.
        try insertInvestigation(store, id: "inv2", question: "What does Router do?", createdAt: "t1")

        let result = try RevisionDiffer.diff(store: store, repositoryId: "repo", newInvestigationId: "inv2")
        XCTAssertTrue(result.entries.allSatisfy { $0.entityType != .component && $0.entityType != .componentRelationship })
    }

    func testFirstArchitectureInvestigationDoesNotDiffComponentsEvenWithPriorAskHistory() throws {
        let (db, store) = try seededRepository()
        try insertSymbol(db, id: "a", anchor: "pkg/mod.py::A")
        try insertSymbol(db, id: "router", anchor: "pkg/mod.py::Router")

        try insertInvestigation(store, id: "ask1", question: "What does A do?", createdAt: "t0")
        try insertClaim(
            store, id: "claim1", investigationId: "ask1", statement: "A does something.",
            subjectRef: "pkg/mod.py::A", evidenceAnchors: ["pkg/mod.py::A"])

        // The first-ever *architecture* investigation, even though prior Ask history exists.
        try insertInvestigation(store, id: "arch1", question: architectureQuestion, createdAt: "t1")
        try insertComponent(store, id: "routing1", investigationId: "arch1", name: "Routing", memberSymbolIds: ["router"])

        let result = try RevisionDiffer.diff(store: store, repositoryId: "repo", newInvestigationId: "arch1")
        XCTAssertTrue(result.entries.allSatisfy { $0.entityType != .component && $0.entityType != .componentRelationship })
    }

    // MARK: - §5 Uncertainty tracking (M3)

    func testCarriedOverUncertaintyWhenWordingIsSimilarEnough() throws {
        let (_, store) = try seededRepository()
        try insertInvestigation(store, id: "inv1", question: architectureQuestion, createdAt: "t0")
        try insertClaim(
            store, id: "unc1", investigationId: "inv1",
            statement: "Whether route matching short-circuits on the first partial match.",
            claimType: "UNKNOWN", subjectRef: nil, evidenceAnchors: [])

        try insertInvestigation(store, id: "inv2", question: architectureQuestion, createdAt: "t1")
        try insertClaim(
            store, id: "unc2", investigationId: "inv2",
            statement: "Whether route matching short-circuits on the first partial match.",
            claimType: "UNKNOWN", subjectRef: nil, evidenceAnchors: [])

        let result = try RevisionDiffer.diff(store: store, repositoryId: "repo", newInvestigationId: "inv2")
        XCTAssertEqual(result.entries.count, 1)
        XCTAssertEqual(result.entries[0].entityType, .uncertainty)
        XCTAssertEqual(result.entries[0].changeType, .carriedOver)
        XCTAssertTrue(result.entries[0].reason.hasPrefix("Still open:"))
    }

    func testNewUncertaintyWithNoPriorMatchIsAdded() throws {
        let (_, store) = try seededRepository()
        try insertInvestigation(store, id: "inv1", question: architectureQuestion, createdAt: "t0")
        try insertClaim(
            store, id: "unc1", investigationId: "inv1", statement: "Whether caching is thread safe.",
            claimType: "UNKNOWN", subjectRef: nil, evidenceAnchors: [])

        try insertInvestigation(store, id: "inv2", question: architectureQuestion, createdAt: "t1")
        try insertClaim(
            store, id: "unc2", investigationId: "inv2",
            statement: "Whether background tasks can outlive the request lifecycle.",
            claimType: "UNKNOWN", subjectRef: nil, evidenceAnchors: [])

        let result = try RevisionDiffer.diff(store: store, repositoryId: "repo", newInvestigationId: "inv2")
        // The previous uncertainty has no match in the new investigation either -- it becomes
        // `.noLongerRaised` (no added claim to plausibly explain it away in this fixture) while
        // the new one is `.added`; both are asserted so this test also documents that shape.
        XCTAssertEqual(result.entries.count, 2)
        let byChangeType = Dictionary(uniqueKeysWithValues: result.entries.map { ($0.changeType, $0) })
        XCTAssertEqual(byChangeType[.added]?.subjectLabel.contains("background tasks"), true)
        XCTAssertEqual(byChangeType[.noLongerRaised]?.subjectLabel.contains("thread safe"), true)
    }

    func testUncertaintyAddressedByPlausiblyOverlappingNewClaim() throws {
        let (db, store) = try seededRepository()
        try insertSymbol(db, id: "cache", anchor: "pkg/mod.py::Cache")
        try insertInvestigation(store, id: "inv1", question: architectureQuestion, createdAt: "t0")
        try insertClaim(
            store, id: "unc1", investigationId: "inv1", statement: "Whether the cache is thread safe.",
            claimType: "UNKNOWN", subjectRef: nil, evidenceAnchors: [])

        try insertInvestigation(store, id: "inv2", question: architectureQuestion, createdAt: "t1")
        try insertClaim(
            store, id: "claim2", investigationId: "inv2",
            statement: "The cache is confirmed thread safe via a lock.",
            subjectRef: "pkg/mod.py::Cache", evidenceAnchors: ["pkg/mod.py::Cache"])

        let result = try RevisionDiffer.diff(store: store, repositoryId: "repo", newInvestigationId: "inv2")
        let uncertaintyEntries = result.entries.filter { $0.entityType == .uncertainty }
        XCTAssertEqual(uncertaintyEntries.count, 1)
        XCTAssertEqual(uncertaintyEntries[0].changeType, .addressed)
        XCTAssertEqual(uncertaintyEntries[0].relatedClaimId, "claim2")
        XCTAssertTrue(uncertaintyEntries[0].reason.contains("Possibly addressed"))
        XCTAssertTrue(uncertaintyEntries[0].reason.contains("not a confirmed resolution"))

        // The new claim itself is still reported as its own `.added` claim entry too -- uncertainty
        // resolution is additive information, not a replacement for ordinary claim diffing.
        XCTAssertTrue(result.entries.contains { $0.entityType == .claim && $0.changeType == .added })
    }

    func testUncertaintyNoLongerRaisedWhenNothingPlausiblyExplainsItEither() throws {
        let (_, store) = try seededRepository()
        try insertInvestigation(store, id: "inv1", question: architectureQuestion, createdAt: "t0")
        try insertClaim(
            store, id: "unc1", investigationId: "inv1",
            statement: "Whether the deprecated legacy exporter is still reachable.",
            claimType: "UNKNOWN", subjectRef: nil, evidenceAnchors: [])

        // A second architecture investigation that raises no uncertainties and no new claims at
        // all -- nothing to carry the old uncertainty over, nothing to plausibly address it.
        try insertInvestigation(store, id: "inv2", question: architectureQuestion, createdAt: "t1")

        let result = try RevisionDiffer.diff(store: store, repositoryId: "repo", newInvestigationId: "inv2")
        XCTAssertEqual(result.entries.count, 1)
        XCTAssertEqual(result.entries[0].entityType, .uncertainty)
        XCTAssertEqual(result.entries[0].changeType, .noLongerRaised)
        XCTAssertNil(result.entries[0].relatedClaimId)
        XCTAssertTrue(result.entries[0].reason.contains("not confirmed either way"))
    }

    func testUncertaintyNeverCarriedOverAcrossDifferentInvestigationKinds() throws {
        let (_, store) = try seededRepository()
        try insertInvestigation(store, id: "inv1", question: architectureQuestion, createdAt: "t0")
        try insertClaim(
            store, id: "unc1", investigationId: "inv1", statement: "Whether X handles concurrent writes.",
            claimType: "UNKNOWN", subjectRef: nil, evidenceAnchors: [])

        // A question-kind investigation raising the near-identical wording -- must not be treated
        // as carried-over from the architecture investigation's uncertainty (§5: "comparing an Ask
        // investigation's uncertainties against an unrelated architecture investigation's would
        // conflate two different questions' open items").
        try insertInvestigation(store, id: "inv2", question: "Does X handle concurrent writes?", createdAt: "t1")
        try insertClaim(
            store, id: "unc2", investigationId: "inv2", statement: "Whether X handles concurrent writes.",
            claimType: "UNKNOWN", subjectRef: nil, evidenceAnchors: [])

        let result = try RevisionDiffer.diff(store: store, repositoryId: "repo", newInvestigationId: "inv2")
        XCTAssertEqual(result.entries.count, 1)
        XCTAssertEqual(result.entries[0].changeType, .added)
    }

    func testBrandNewUncertaintyOnRepositorysFirstEverInvestigationIsAddedNotEmpty() throws {
        // The one deliberate exception to "the very first investigation for a repository can
        // never produce a revision" (§9 Risk #5, amended in M3): an open question is worth
        // recording the first time it's ever raised, since there's nothing to meaningfully
        // compare its *absence* against in the first place.
        let (_, store) = try seededRepository()
        try insertInvestigation(store, id: "inv1", question: architectureQuestion, createdAt: "t0")
        try insertClaim(
            store, id: "unc1", investigationId: "inv1", statement: "Whether X is thread safe.",
            claimType: "UNKNOWN", subjectRef: nil, evidenceAnchors: [])

        let result = try RevisionDiffer.diff(store: store, repositoryId: "repo", newInvestigationId: "inv1")
        XCTAssertEqual(result.entries.count, 1)
        XCTAssertEqual(result.entries[0].entityType, .uncertainty)
        XCTAssertEqual(result.entries[0].changeType, .added)
    }

    // MARK: - Regression: a claim is still `.added` even when an earlier investigation had none

    func testClaimStillAddedWhenAnEarlierInvestigationHadNoClaimsAtAll() throws {
        // A real bug found and fixed while building M3, not caught by any M2 fixture: an early
        // version of `diffClaims` returned early whenever the *historical* claim pool ended up
        // empty, even if prior investigations existed -- silently dropping `.added` entries for a
        // second investigation's genuinely new claims whenever the first investigation happened to
        // have none of its own. This reproduces exactly that shape.
        let (db, store) = try seededRepository()
        try insertSymbol(db, id: "router", anchor: "pkg/mod.py::Router")
        try insertInvestigation(store, id: "inv1", question: architectureQuestion, createdAt: "t0")
        // inv1 has a component but zero claims.
        try insertComponent(store, id: "routing1", investigationId: "inv1", name: "Routing", memberSymbolIds: ["router"])

        try insertInvestigation(store, id: "inv2", question: "What does Router do?", createdAt: "t1")
        try insertClaim(
            store, id: "claim2", investigationId: "inv2", statement: "Router dispatches requests.",
            subjectRef: "pkg/mod.py::Router", evidenceAnchors: ["pkg/mod.py::Router"])

        let result = try RevisionDiffer.diff(store: store, repositoryId: "repo", newInvestigationId: "inv2")
        let claimEntries = result.entries.filter { $0.entityType == .claim }
        XCTAssertEqual(claimEntries.count, 1)
        XCTAssertEqual(claimEntries[0].changeType, .added)
    }

    // MARK: - Regression: claim diffing must never look forward in time (M6)

    /// A real, load-bearing bug found against real data (Docs/16 M6, discovered while backfilling
    /// the real vendored-Starlette research database): `diffClaims` used to gather "every *other*
    /// investigation" as history to match against, not "every investigation *strictly earlier*
    /// than this one." Every prior test always diffed the most-recently-created investigation, so
    /// the two sets were always identical by construction and this never surfaced -- diffing an
    /// *older* investigation while *newer* ones already exist (exactly what a backfill over real
    /// historical data does) exposes it directly: an investigation's own claims got matched
    /// against, and reported as `.modified` relative to, claims from investigations that happened
    /// chronologically *after* it. Reproduces that shape minimally and confirms the fix.
    func testClaimDiffingNeverMatchesAgainstALaterInvestigation() throws {
        let (db, store) = try seededRepository()
        try insertSymbol(db, id: "a", anchor: "pkg/mod.py::A")
        try insertInvestigation(store, id: "inv1", question: architectureQuestion, createdAt: "t0")
        try insertClaim(
            store, id: "claim1", investigationId: "inv1", statement: "A coordinates state.",
            subjectRef: "pkg/mod.py::A", evidenceAnchors: ["pkg/mod.py::A"])

        // A *later* investigation whose claim would otherwise (wrongly) look like inv1's own
        // claim "refined."
        try insertInvestigation(store, id: "inv2", question: "Tell me more about A.", createdAt: "t1")
        try insertClaim(
            store, id: "claim2", investigationId: "inv2", statement: "A coordinates state and logs it.",
            subjectRef: "pkg/mod.py::A", evidenceAnchors: ["pkg/mod.py::A"])

        // Diffing inv1 -- the *earlier* investigation -- must find nothing: it is this
        // repository's first investigation, and inv2 (its only possible "match") happened after
        // it, not before.
        let result = try RevisionDiffer.diff(store: store, repositoryId: "repo", newInvestigationId: "inv1")
        XCTAssertTrue(
            result.entries.isEmpty,
            "inv1 must never diff against inv2, which happened after it: \(result.entries)")
    }
}
