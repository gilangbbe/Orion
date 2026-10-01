import XCTest
@testable import OrionCodeIntel
@testable import OrionCore

/// Docs/17 M1: `ConceptExtractor` against fixture data — real `Store`, hand-built rows, no model
/// call, matching `RevisionDifferTests`/`SemanticImporterTests`' own established pattern for
/// schema-adjacent logic.
final class ConceptExtractorTests: XCTestCase {

    // MARK: - Fixture helpers

    private func seed() throws -> (db: OrionDatabase, store: Store) {
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
                path: "m/a.py", language: "python", modulePath: "m.a", sha256: "x",
                byteSize: 10, lineCount: 10, isTest: false, isPackageInit: false, parseOk: true
            ).insert(dbc)
        }
        return (db, store)
    }

    private func sym(_ db: OrionDatabase, _ id: String, _ anchor: String) throws {
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

    private func rel(_ db: OrionDatabase, _ id: String, _ src: String, _ dst: String) throws {
        try db.dbQueue.write { dbc in
            try RelationshipRecord(
                id: id, repositoryId: "repo", commitHash: "c0ffee", runId: "run",
                relationshipType: "calls", sourceSymbolId: src, targetSymbolId: dst,
                externalDependencyId: nil, sourceRef: nil, targetRef: nil, provenance: "scip",
                confidence: 0.9, confidenceTier: "high", resolved: true, epistemicType: "FACT",
                siteFileId: nil, siteStartLine: nil, siteStartCol: nil, siteEndLine: nil,
                siteEndCol: nil
            ).insert(dbc)
        }
    }

    private func investigation(_ store: Store, _ id: String, arch: Bool, _ createdAt: String) throws {
        try store.insertInvestigation(InvestigationRecord(
            id: id, repositoryId: "repo", commitHash: "c0ffee", runId: "run",
            question: arch ? InvestigationRecord.architectureQuestionMarker : "what does A do?",
            complexity: "high", outcome: "verified", createdAt: createdAt))
    }

    @discardableResult
    private func comp(_ store: Store, _ id: String, _ invId: String, _ name: String) throws -> String {
        try store.insertComponents([ComponentRecord(
            id: id, repositoryId: "repo", commitHash: "c0ffee", runId: "run", investigationId: invId,
            name: name, description: "desc of \(name)", architecturalRole: "core", confidence: 0.9,
            confidenceTier: "high", status: "active", epistemicType: "INTERPRETATION",
            provenance: "claude_code")])
        return id
    }

    private func member(_ store: Store, _ compId: String, _ symbolId: String) throws {
        try store.insertComponentMembers([ComponentMemberRecord(
            id: "\(compId)-\(symbolId)", componentId: compId, symbolId: symbolId, confidence: 0.9,
            role: "core")])
    }

    private func crel(
        _ store: Store, _ id: String, _ invId: String, _ src: String, _ dst: String
    ) throws {
        try store.insertComponentRelationships([ComponentRelationshipRecord(
            id: id, repositoryId: "repo", commitHash: "c0ffee", runId: "run", investigationId: invId,
            sourceComponentId: src, targetComponentId: dst, relationshipType: "depends_on",
            confidence: 0.6, confidenceTier: "medium", provenance: "claude_code")])
    }

    private func claim(
        _ store: Store, _ id: String, _ invId: String, _ statement: String, type: String, anchors: [String]
    ) throws {
        try store.insertClaims([ClaimRecord(
            id: id, repositoryId: "repo", commitHash: "c0ffee", runId: "run", investigationId: invId,
            subjectRef: anchors.first, predicate: nil, objectRef: nil, statement: statement,
            claimType: type, confidence: 0.8, status: "active", createdBy: "claude_code")])
        try store.insertEvidence(anchors.enumerated().map { i, a in
            EvidenceRecord(id: "\(id)-e\(i)", claimId: id, fileId: "file1", symbolId: nil,
                           anchor: a, startLine: nil, endLine: nil, evidenceType: "source")
        })
    }

    private func extract(_ store: Store, cap: Int = ConceptExtractor.defaultCap) throws -> ConceptExtractor.Result {
        try ConceptExtractor.extract(store: store, commitHash: "c0ffee", cap: cap, now: "tX")
    }

    // MARK: - Tests

    func testDerivesComponentClaimAndRelationshipConcepts() throws {
        let (db, store) = try seed()
        try sym(db, "s1", "m/a.py::A"); try sym(db, "s2", "m/a.py::helper")
        try sym(db, "s3", "m/a.py::B")
        try investigation(store, "arch", arch: true, "t0")
        let a = try comp(store, "cA", "arch", "Alpha"); try member(store, a, "s1"); try member(store, a, "s2")
        let b = try comp(store, "cB", "arch", "Beta"); try member(store, b, "s3")
        try crel(store, "cr1", "arch", "cA", "cB")
        try claim(store, "cl1", "arch", "Alpha coordinates request handling.",
                  type: "INTERPRETATION", anchors: ["m/a.py::A"])

        let r = try extract(store)
        XCTAssertEqual(r.inserted.count, 4)
        XCTAssertEqual(r.kept, 4)

        let concepts = try store.teachingConcepts(repositoryId: "repo")
        let byLabel = Dictionary(uniqueKeysWithValues: concepts.map { ($0.subjectLabel, $0) })
        XCTAssertEqual(byLabel["Alpha"]?.kind, "component")
        XCTAssertEqual(byLabel["Alpha"]?.difficultyBand, 1)
        XCTAssertEqual(byLabel["Alpha"]?.sourceComponentId, "cA")
        XCTAssertEqual(byLabel["Beta"]?.kind, "component")
        XCTAssertEqual(byLabel["Alpha \u{2192} Beta"]?.kind, "relationship")
        XCTAssertEqual(byLabel["Alpha \u{2192} Beta"]?.difficultyBand, 2)
        XCTAssertEqual(byLabel["Alpha \u{2192} Beta"]?.sourceComponentId, "cA")
        let claimConcept = try XCTUnwrap(byLabel["Alpha coordinates request handling."])
        XCTAssertEqual(claimConcept.kind, "claim")
        XCTAssertEqual(claimConcept.sourceClaimId, "cl1")
        XCTAssertEqual(claimConcept.difficultyBand, 1)   // single evidence anchor
    }

    func testComponentConceptAnchorsAreSortedMembers() throws {
        let (db, store) = try seed()
        try sym(db, "s1", "m/a.py::Zeta"); try sym(db, "s2", "m/a.py::Alpha")
        try investigation(store, "arch", arch: true, "t0")
        let a = try comp(store, "cA", "arch", "C"); try member(store, a, "s1"); try member(store, a, "s2")

        _ = try extract(store)
        let concept = try XCTUnwrap(try store.teachingConcepts(repositoryId: "repo").first)
        XCTAssertEqual(concept.evidenceAnchors, ["m/a.py::Alpha", "m/a.py::Zeta"])
    }

    func testClaimWithNoResolvableEvidenceProducesNoConcept() throws {
        let (db, store) = try seed()
        try sym(db, "s1", "m/a.py::A")
        try investigation(store, "ask", arch: false, "t0")
        try claim(store, "cl1", "ask", "A does something.", type: "INTERPRETATION",
                  anchors: ["m/a.py::Ghost"])   // no such symbol

        let r = try extract(store)
        XCTAssertEqual(r.inserted.count, 0)
        XCTAssertEqual(try store.teachingConcepts(repositoryId: "repo").count, 0)
    }

    func testUnknownClaimExcluded() throws {
        let (db, store) = try seed()
        try sym(db, "s1", "m/a.py::A")
        try investigation(store, "ask", arch: false, "t0")
        try claim(store, "cl1", "ask", "Whether A is thread-safe.", type: "UNKNOWN",
                  anchors: ["m/a.py::A"])
        XCTAssertEqual(try extract(store).inserted.count, 0)
    }

    func testCentralityNormalisedToMaxOne() throws {
        let (db, store) = try seed()
        try sym(db, "s1", "m/a.py::Hub"); try sym(db, "s2", "m/a.py::Leaf")
        try sym(db, "x1", "m/a.py::x1"); try sym(db, "x2", "m/a.py::x2")
        try rel(db, "r1", "s1", "x1"); try rel(db, "r2", "s1", "x2")   // Hub degree 2, Leaf degree 0
        try investigation(store, "arch", arch: true, "t0")
        let a = try comp(store, "cHub", "arch", "HubComp"); try member(store, a, "s1")
        let b = try comp(store, "cLeaf", "arch", "LeafComp"); try member(store, b, "s2")

        _ = try extract(store)
        let byLabel = Dictionary(
            uniqueKeysWithValues: try store.teachingConcepts(repositoryId: "repo").map {
                ($0.subjectLabel, $0)
            })
        XCTAssertEqual(try XCTUnwrap(byLabel["HubComp"]).centrality, 1.0, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(byLabel["LeafComp"]).centrality, 0.0, accuracy: 1e-9)
    }

    func testDedupCollapsesOverlappingConceptsKeepingHigherCentrality() throws {
        let (db, store) = try seed()
        // A = {s1,s2,s3,s4}, B = {s1,s2,s3,s5}  ->  Jaccard = 3/5 = 0.6 (>= threshold).
        for (id, name) in [("s1", "s1"), ("s2", "s2"), ("s3", "s3"), ("s4", "s4"), ("s5", "s5")] {
            try sym(db, id, "m/a.py::\(name)")
        }
        // Give s5 a big degree so B outscores A on centrality.
        try sym(db, "x1", "m/a.py::x1"); try sym(db, "x2", "m/a.py::x2"); try sym(db, "x3", "m/a.py::x3")
        try rel(db, "r1", "s5", "x1"); try rel(db, "r2", "s5", "x2"); try rel(db, "r3", "s5", "x3")
        try investigation(store, "arch", arch: true, "t0")
        let a = try comp(store, "cA", "arch", "Aaa")
        for s in ["s1", "s2", "s3", "s4"] { try member(store, a, s) }
        let b = try comp(store, "cB", "arch", "Bbb")
        for s in ["s1", "s2", "s3", "s5"] { try member(store, b, s) }

        let r = try extract(store)
        XCTAssertEqual(r.deduped, 1)
        let concepts = try store.teachingConcepts(repositoryId: "repo")
        XCTAssertEqual(concepts.count, 1)
        XCTAssertEqual(concepts.first?.subjectLabel, "Bbb")   // higher centrality wins
    }

    func testCapKeepsTopNByCentrality() throws {
        let (db, store) = try seed()
        try sym(db, "hi", "m/a.py::hi"); try sym(db, "mid", "m/a.py::mid"); try sym(db, "lo", "m/a.py::lo")
        try sym(db, "x1", "m/a.py::x1"); try sym(db, "x2", "m/a.py::x2"); try sym(db, "x3", "m/a.py::x3")
        try rel(db, "r1", "hi", "x1"); try rel(db, "r2", "hi", "x2"); try rel(db, "r3", "hi", "x3")
        try rel(db, "r4", "mid", "x1")   // mid degree 1, lo degree 0
        try investigation(store, "arch", arch: true, "t0")
        for (cid, name, sid) in [("cHi", "Hi", "hi"), ("cMid", "Mid", "mid"), ("cLo", "Lo", "lo")] {
            let c = try comp(store, cid, "arch", name); try member(store, c, sid)
        }

        let r = try extract(store, cap: 2)
        XCTAssertEqual(r.inserted.count, 2)
        XCTAssertEqual(r.cappedOut, 1)
        XCTAssertEqual(
            Set(try store.teachingConcepts(repositoryId: "repo").map(\.subjectLabel)), ["Hi", "Mid"])
    }

    func testReRunIsIdempotent() throws {
        let (db, store) = try seed()
        try sym(db, "s1", "m/a.py::A")
        try investigation(store, "arch", arch: true, "t0")
        let a = try comp(store, "cA", "arch", "Alpha"); try member(store, a, "s1")

        let first = try extract(store)
        XCTAssertEqual(first.inserted.count, 1)

        let second = try extract(store)
        XCTAssertTrue(second.inserted.isEmpty)
        XCTAssertTrue(second.restaled.isEmpty)
        XCTAssertTrue(second.revived.isEmpty)
        XCTAssertEqual(second.kept, 1)
        XCTAssertEqual(try store.teachingConcepts(repositoryId: "repo").count, 1)
    }

    func testMissingSourceIsRestaledThenRevived() throws {
        let (db, store) = try seed()
        try sym(db, "s1", "m/a.py::A"); try sym(db, "s2", "m/a.py::B")
        try investigation(store, "arch1", arch: true, "t0")
        let a1 = try comp(store, "cA1", "arch1", "Alpha"); try member(store, a1, "s1")
        let b1 = try comp(store, "cB1", "arch1", "Beta"); try member(store, b1, "s2")
        _ = try extract(store)
        let betaId = try XCTUnwrap(
            try store.teachingConcepts(repositoryId: "repo").first { $0.subjectLabel == "Beta" }).id

        // A newer architecture investigation that no longer has "Beta".
        try investigation(store, "arch2", arch: true, "t1")
        let a2 = try comp(store, "cA2", "arch2", "Alpha"); try member(store, a2, "s1")
        let restaled = try extract(store)
        XCTAssertEqual(restaled.restaled, [betaId])
        XCTAssertEqual(try store.teachingConcepts(repositoryId: "repo").map(\.subjectLabel), ["Alpha"])
        XCTAssertTrue(try XCTUnwrap(store.teachingConcept(id: betaId)).stale)

        // "Beta" comes back in a still-newer investigation.
        try investigation(store, "arch3", arch: true, "t2")
        let a3 = try comp(store, "cA3", "arch3", "Alpha"); try member(store, a3, "s1")
        let b3 = try comp(store, "cB3", "arch3", "Beta"); try member(store, b3, "s2")
        let revived = try extract(store)
        XCTAssertEqual(revived.revived, [betaId])
        XCTAssertFalse(try XCTUnwrap(store.teachingConcept(id: betaId)).stale)
        XCTAssertEqual(
            Set(try store.teachingConcepts(repositoryId: "repo").map(\.subjectLabel)), ["Alpha", "Beta"])
    }

    func testNoArchitectureInvestigationStillDerivesClaimConcepts() throws {
        let (db, store) = try seed()
        try sym(db, "s1", "m/a.py::A")
        try investigation(store, "ask", arch: false, "t0")
        try claim(store, "cl1", "ask", "A validates the request body.", type: "INTERPRETATION",
                  anchors: ["m/a.py::A"])

        let r = try extract(store)
        XCTAssertEqual(r.inserted.count, 1)
        let concepts = try store.teachingConcepts(repositoryId: "repo")
        XCTAssertEqual(concepts.map(\.kind), ["claim"])
    }

    func testEmptyWhenNoRun() throws {
        let db = try OrionDatabase(inMemory: true)
        let r = try ConceptExtractor.extract(store: Store(db), now: "tX")
        XCTAssertEqual(r, ConceptExtractor.Result())
    }
}
