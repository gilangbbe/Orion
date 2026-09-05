import XCTest
import GRDB
@testable import OrionCodeIntel

/// Docs/11: `SemanticImporter`, the full validation pipeline — schema (step 1), evidence
/// (step 2, M0), consistency check (step 3, M2), and Codebase Model persistence (step 4, M2).
/// Export (step 5) is M3.
final class SemanticImporterTests: XCTestCase {

    // MARK: - a real analyzed DB, for realistic anchors and a real Phase 1 relationship graph

    private var keepAlive: [TempDir] = []

    /// `pkg/a.py` imports `pkg/b.py` (a real `imports` edge between their module symbols);
    /// `pkg/c.py` has no relationship to either — the fixture step 3's connectivity checks
    /// (component-relationship confirmation, claim-contradiction) need a real "connected" pair
    /// and a real "unconnected" pair to exercise both branches.
    private func analyzed() throws -> Store {
        let repo = try TempDir()
        keepAlive.append(repo)
        let git = GitRunner(repoPath: repo.url)
        _ = try git.run(["init", "--quiet", "-b", "main"])
        _ = try git.run(["config", "user.email", "t@e.com"])
        _ = try git.run(["config", "user.name", "T"])
        try repo.write("pkg/__init__.py", "")
        try repo.write("pkg/a.py", "from pkg import b\n\nclass Widget:\n    def run(self):\n        return 1\n")
        try repo.write("pkg/b.py", "VALUE = 1\n")
        try repo.write("pkg/c.py", "class Gamma:\n    pass\n")
        _ = try git.run(["add", "."])
        _ = try git.run(["commit", "--quiet", "-m", "init"])

        let out = try TempDir()
        keepAlive.append(out)
        let db = try OrionDatabase(path: out.path("orion.db"))
        _ = try AnalysisPipeline(database: db).run(
            AnalysisInput(repoPath: repo.url, outputDirectory: out.url, resolve: false, export: false)
        )
        return Store(db)
    }

    private func decode(_ json: String) throws -> SemanticFindings {
        try SemanticImporter(store: Store(try OrionDatabase(inMemory: true)))
            .decode(data: Data(json.utf8))
    }

    private func writeCandidate(_ json: String) throws -> URL {
        let dir = try TempDir(); keepAlive.append(dir)
        try dir.write("candidate.json", json)
        return URL(fileURLWithPath: dir.path("candidate.json"))
    }

    // MARK: - step 1: schema validation

    func testValidateSchemaAcceptsWellFormedCandidate() throws {
        let findings = try decode(Self.validJSON)
        let importer = SemanticImporter(store: Store(try OrionDatabase(inMemory: true)))
        XCTAssertEqual(importer.validateSchema(findings), [])
    }

    func testValidateSchemaRejectsWrongVersion() throws {
        let findings = try decode(Self.validJSON.replacingOccurrences(
            of: "\"phase2.v1\"", with: "\"phase1.v9\""
        ))
        let importer = SemanticImporter(store: Store(try OrionDatabase(inMemory: true)))
        let errors = importer.validateSchema(findings)
        XCTAssertTrue(errors.contains { $0.contains("schema_version") })
    }

    func testValidateSchemaRejectsEmptyMembersAndBadConfidence() throws {
        let json = """
        {
          "schema_version": "phase2.v1",
          "components": [{"name": "Widgets", "members": []}],
          "component_relationships": [],
          "claims": [{"claim_type": "INTERPRETATION", "statement": "x", "evidence": [], "confidence": "extreme"}],
          "uncertainties": []
        }
        """
        let findings = try decode(json)
        let importer = SemanticImporter(store: Store(try OrionDatabase(inMemory: true)))
        let errors = importer.validateSchema(findings)
        XCTAssertTrue(errors.contains { $0.contains("components[0].members is empty") })
        XCTAssertTrue(errors.contains { $0.contains("confidence") })
    }

    func testDecodeRejectsUnknownClaimType() {
        // FACT/CONTRADICTED are not decodable claim_type values -- Claude never self-tags them.
        let json = """
        {"schema_version":"phase2.v1","components":[],"component_relationships":[],
         "claims":[{"claim_type":"FACT","statement":"x","evidence":[],"confidence":"high"}],
         "uncertainties":[]}
        """
        XCTAssertThrowsError(try decode(json))
    }

    // MARK: - step 2: evidence validation

    func testValidateEvidenceResolvesRealAnchors() throws {
        let store = try analyzed()
        let json = """
        {
          "schema_version": "phase2.v1",
          "components": [{
            "name": "Widgets", "description": "Widget stuff.", "architectural_role": "core",
            "members": ["pkg/a.py::Widget", "pkg/a.py::Widget.run"]
          }],
          "component_relationships": [],
          "claims": [{
            "claim_type": "INTERPRETATION", "statement": "Widget.run returns a constant.",
            "evidence": ["pkg/a.py::Widget.run"], "confidence": "high"
          }],
          "uncertainties": []
        }
        """
        let findings = try decode(json)
        let importer = SemanticImporter(store: store)
        let run = try XCTUnwrap(store.latestRun(commitHash: nil))
        let outcome = try importer.validateEvidence(findings, runId: run.id)

        XCTAssertEqual(outcome.components.count, 1)
        XCTAssertEqual(outcome.components[0].members.count, 2)
        XCTAssertEqual(outcome.droppedComponents, [])
        XCTAssertEqual(outcome.claims.count, 1)
        XCTAssertEqual(outcome.claims[0].evidence.first?.anchor, "pkg/a.py::Widget.run")
        // the evidence range is copied from the resolved symbol, not invented by Claude
        XCTAssertGreaterThanOrEqual(outcome.claims[0].evidence[0].endLine, outcome.claims[0].evidence[0].startLine)
        XCTAssertEqual(outcome.diagnostics, [])
    }

    func testValidateEvidenceDropsComponentWithNoResolvableMembers() throws {
        let store = try analyzed()
        let json = """
        {
          "schema_version": "phase2.v1",
          "components": [{"name": "Ghosts", "members": ["pkg/a.py::Nope"]}],
          "component_relationships": [],
          "claims": [], "uncertainties": []
        }
        """
        let findings = try decode(json)
        let importer = SemanticImporter(store: store)
        let run = try XCTUnwrap(store.latestRun(commitHash: nil))
        let outcome = try importer.validateEvidence(findings, runId: run.id)

        XCTAssertEqual(outcome.components, [])
        XCTAssertEqual(outcome.droppedComponents, ["Ghosts"])
        XCTAssertTrue(outcome.diagnostics.contains(
            .anchorUnresolved(context: "component 'Ghosts'", anchor: "pkg/a.py::Nope")
        ))
        XCTAssertTrue(outcome.diagnostics.contains {
            if case .componentDropped(let name, _) = $0 { return name == "Ghosts" }
            return false
        })
    }

    func testValidateEvidenceDropsClaimWithNoResolvableEvidence() throws {
        let store = try analyzed()
        let json = """
        {
          "schema_version": "phase2.v1",
          "components": [], "component_relationships": [],
          "claims": [{
            "claim_type": "INFERENCE", "statement": "Unfounded.",
            "evidence": ["pkg/a.py::Nope"], "confidence": "low"
          }],
          "uncertainties": []
        }
        """
        let findings = try decode(json)
        let importer = SemanticImporter(store: store)
        let run = try XCTUnwrap(store.latestRun(commitHash: nil))
        let outcome = try importer.validateEvidence(findings, runId: run.id)

        XCTAssertEqual(outcome.claims, [])
        XCTAssertEqual(outcome.droppedClaims, ["Unfounded."])
    }

    func testComponentRelationshipDroppedWhenEitherComponentIsDropped() throws {
        let store = try analyzed()
        let json = """
        {
          "schema_version": "phase2.v1",
          "components": [{"name": "Widgets", "members": ["pkg/a.py::Widget"]}],
          "component_relationships": [{"source": "Widgets", "target": "Ghosts", "type": "depends_on"}],
          "claims": [], "uncertainties": []
        }
        """
        let findings = try decode(json)
        let importer = SemanticImporter(store: store)
        let run = try XCTUnwrap(store.latestRun(commitHash: nil))
        let outcome = try importer.validateEvidence(findings, runId: run.id)

        XCTAssertEqual(outcome.componentRelationships, [])
        XCTAssertEqual(outcome.droppedComponentRelationships.count, 1)
    }

    func testUncertaintiesBecomeUnknownClaimsRequiringNoEvidence() throws {
        let store = try analyzed()
        let json = """
        {
          "schema_version": "phase2.v1",
          "components": [], "component_relationships": [], "claims": [],
          "uncertainties": ["Whether X short-circuits."]
        }
        """
        let findings = try decode(json)
        let importer = SemanticImporter(store: store)
        let run = try XCTUnwrap(store.latestRun(commitHash: nil))
        let outcome = try importer.validateEvidence(findings, runId: run.id)

        XCTAssertEqual(outcome.claims.count, 1)
        XCTAssertEqual(outcome.claims[0].claimType, .unknown)
        XCTAssertEqual(outcome.claims[0].evidence, [])
        XCTAssertEqual(outcome.droppedClaims, [])
    }

    // MARK: - step 3: consistency check

    func testDuplicateComponentNameKeepsFirstDropsSecond() throws {
        let store = try analyzed()
        let run = try XCTUnwrap(store.latestRun(commitHash: nil))
        let json = """
        {
          "schema_version": "phase2.v1",
          "components": [
            {"name": "Widgets", "members": ["pkg/a.py::Widget"]},
            {"name": "Widgets", "members": ["pkg/b.py"]}
          ],
          "component_relationships": [], "claims": [], "uncertainties": []
        }
        """
        let findings = try decode(json)
        let importer = SemanticImporter(store: store)
        let validated = try importer.validateEvidence(findings, runId: run.id)
        let consistent = try importer.applyConsistencyCheck(validated, runId: run.id)

        XCTAssertEqual(consistent.components.count, 1)
        XCTAssertEqual(consistent.components[0].members.map(\.anchor), ["pkg/a.py::Widget"])
        XCTAssertEqual(consistent.duplicateComponentsDropped, ["Widgets"])
        XCTAssertTrue(consistent.diagnostics.contains(.duplicateComponent(name: "Widgets")))
    }

    func testComponentRelationshipConfirmedAgainstRealImportEdge() throws {
        let store = try analyzed()
        let run = try XCTUnwrap(store.latestRun(commitHash: nil))
        let json = """
        {
          "schema_version": "phase2.v1",
          "components": [
            {"name": "Alpha", "members": ["pkg/a.py"]},
            {"name": "Beta", "members": ["pkg/b.py"]}
          ],
          "component_relationships": [{"source": "Alpha", "target": "Beta", "type": "depends_on"}],
          "claims": [], "uncertainties": []
        }
        """
        let findings = try decode(json)
        let importer = SemanticImporter(store: store)
        let validated = try importer.validateEvidence(findings, runId: run.id)
        let consistent = try importer.applyConsistencyCheck(validated, runId: run.id)

        XCTAssertEqual(consistent.componentRelationships.count, 1)
        XCTAssertEqual(consistent.componentRelationships[0].confidenceTier, .high)
    }

    func testComponentRelationshipUnconfirmedWhenNoRealEdgeExists() throws {
        let store = try analyzed()
        let run = try XCTUnwrap(store.latestRun(commitHash: nil))
        let json = """
        {
          "schema_version": "phase2.v1",
          "components": [
            {"name": "Alpha", "members": ["pkg/a.py"]},
            {"name": "Gamma", "members": ["pkg/c.py"]}
          ],
          "component_relationships": [{"source": "Alpha", "target": "Gamma", "type": "depends_on"}],
          "claims": [], "uncertainties": []
        }
        """
        let findings = try decode(json)
        let importer = SemanticImporter(store: store)
        let validated = try importer.validateEvidence(findings, runId: run.id)
        let consistent = try importer.applyConsistencyCheck(validated, runId: run.id)

        // kept, not dropped -- an unconfirmed relationship is still informative
        XCTAssertEqual(consistent.componentRelationships.count, 1)
        XCTAssertEqual(consistent.componentRelationships[0].confidenceTier, .unresolved)
        XCTAssertTrue(consistent.diagnostics.contains(
            .componentRelationshipUnconfirmed(source: "Alpha", target: "Gamma")
        ))
    }

    func testMultiEvidenceClaimReclassifiedContradictedWhenSymbolsDontConnect() throws {
        let store = try analyzed()
        let run = try XCTUnwrap(store.latestRun(commitHash: nil))
        let json = """
        {
          "schema_version": "phase2.v1",
          "components": [], "component_relationships": [],
          "claims": [{
            "claim_type": "INFERENCE", "statement": "a.py and c.py are related.",
            "evidence": ["pkg/a.py", "pkg/c.py"], "confidence": "high"
          }],
          "uncertainties": []
        }
        """
        let findings = try decode(json)
        let importer = SemanticImporter(store: store)
        let validated = try importer.validateEvidence(findings, runId: run.id)
        let consistent = try importer.applyConsistencyCheck(validated, runId: run.id)

        XCTAssertEqual(consistent.claims.count, 1)
        XCTAssertEqual(consistent.claims[0].claimType, .contradicted)
        XCTAssertTrue(consistent.diagnostics.contains(.claimContradicted(statement: "a.py and c.py are related.")))
    }

    func testMultiEvidenceClaimKeepsAssertedTypeWhenSymbolsDoConnect() throws {
        let store = try analyzed()
        let run = try XCTUnwrap(store.latestRun(commitHash: nil))
        let json = """
        {
          "schema_version": "phase2.v1",
          "components": [], "component_relationships": [],
          "claims": [{
            "claim_type": "INTERPRETATION", "statement": "a.py imports b.py.",
            "evidence": ["pkg/a.py", "pkg/b.py"], "confidence": "high"
          }],
          "uncertainties": []
        }
        """
        let findings = try decode(json)
        let importer = SemanticImporter(store: store)
        let validated = try importer.validateEvidence(findings, runId: run.id)
        let consistent = try importer.applyConsistencyCheck(validated, runId: run.id)

        XCTAssertEqual(consistent.claims.count, 1)
        XCTAssertEqual(consistent.claims[0].claimType, .interpretation)
    }

    // MARK: - full `ingest` entry point (steps 1-4, persisted)

    func testIngestRejectsDecodeFailureButStillPersistsInvestigation() throws {
        let store = try analyzed()
        let run = try XCTUnwrap(store.latestRun(commitHash: nil))
        let candidateURL = try writeCandidate("not json at all")
        let importer = SemanticImporter(store: store)

        XCTAssertThrowsError(
            try importer.ingest(candidateURL: candidateURL, metaURL: nil, run: run, now: "t0")
        ) { error in
            guard case SemanticImportError.decodeFailed(_, let inv) = error else {
                return XCTFail("expected .decodeFailed, got \(error)")
            }
            XCTAssertEqual(inv.outcome, InvestigationOutcome.rejected.rawValue)
            XCTAssertNil(inv.schemaVersion)
        }
    }

    func testIngestRejectsSchemaMismatchButStillPersistsInvestigation() throws {
        let store = try analyzed()
        let run = try XCTUnwrap(store.latestRun(commitHash: nil))
        let candidateURL = try writeCandidate(
            Self.validJSON.replacingOccurrences(of: "\"phase2.v1\"", with: "\"bogus\"")
        )
        let importer = SemanticImporter(store: store)

        XCTAssertThrowsError(
            try importer.ingest(candidateURL: candidateURL, metaURL: nil, run: run, now: "t0")
        ) { error in
            guard case SemanticImportError.schemaInvalid(_, let inv) = error else {
                return XCTFail("expected .schemaInvalid, got \(error)")
            }
            XCTAssertEqual(inv.outcome, InvestigationOutcome.rejected.rawValue)
            XCTAssertEqual(inv.schemaVersion, "bogus")
        }
        // the rejected attempt is still queryable
        try store.db.dbQueue.read { dbc in
            XCTAssertEqual(try InvestigationRecord.fetchCount(dbc), 1)
            XCTAssertEqual(try ComponentRecord.fetchCount(dbc), 0)
        }
    }

    func testIngestPersistsCleanCandidateAsVerified() throws {
        let store = try analyzed()
        let run = try XCTUnwrap(store.latestRun(commitHash: nil))
        let candidateURL = try writeCandidate("""
        {
          "schema_version": "phase2.v1",
          "components": [
            {"name": "Alpha", "description": "A.", "architectural_role": "core", "members": ["pkg/a.py"]},
            {"name": "Beta", "members": ["pkg/b.py"]}
          ],
          "component_relationships": [{"source": "Alpha", "target": "Beta", "type": "depends_on"}],
          "claims": [{
            "claim_type": "INTERPRETATION", "statement": "a.py imports b.py.",
            "evidence": ["pkg/a.py", "pkg/b.py"], "confidence": "high"
          }],
          "uncertainties": ["Something unverified."]
        }
        """)
        let metaURL = try writeMeta("""
        {"model_used": "claude-sonnet-5", "session_id": "sess-1", "num_turns": 4,
         "total_cost_usd": 0.5, "duration_ms": 1000.0, "tools_used": ["Read", "Grep", "Glob"]}
        """)
        let importer = SemanticImporter(store: store)
        let outcome = try importer.ingest(candidateURL: candidateURL, metaURL: metaURL, run: run, now: "t0")

        XCTAssertEqual(outcome.investigation.outcome, InvestigationOutcome.verified.rawValue)
        XCTAssertEqual(outcome.investigation.modelUsed, "claude-sonnet-5")
        XCTAssertEqual(outcome.investigation.sessionId, "sess-1")
        XCTAssertEqual(outcome.investigation.numTurns, 4)
        XCTAssertEqual(outcome.consistent.components.count, 2)
        XCTAssertEqual(outcome.consistent.componentRelationships.count, 1)
        // 1 evidenced claim + 1 uncertainty-derived UNKNOWN claim
        XCTAssertEqual(outcome.consistent.claims.count, 2)

        try store.db.dbQueue.read { dbc in
            XCTAssertEqual(try ComponentRecord.fetchCount(dbc), 2)
            XCTAssertEqual(try ComponentMemberRecord.fetchCount(dbc), 2)
            XCTAssertEqual(try ComponentRelationshipRecord.fetchCount(dbc), 1)
            XCTAssertEqual(try ClaimRecord.fetchCount(dbc), 2)
            XCTAssertEqual(try EvidenceRecord.fetchCount(dbc), 2)  // only the evidenced claim
            XCTAssertEqual(try ModelRevisionRecord.fetchCount(dbc), 1)
        }
    }

    func testIngestBackfillsSymbolComponentIdToHighestConfidenceMembership() throws {
        let store = try analyzed()
        let run = try XCTUnwrap(store.latestRun(commitHash: nil))
        // "pkg/a.py::Widget" is a member of both -- HighConf has zero dropped members (tier
        // high), LowConf has one unresolvable member (tier medium); the shared symbol's
        // component_id must end up HighConf's.
        let candidateURL = try writeCandidate("""
        {
          "schema_version": "phase2.v1",
          "components": [
            {"name": "LowConf", "members": ["pkg/a.py::Widget", "pkg/nope.py::Ghost"]},
            {"name": "HighConf", "members": ["pkg/a.py::Widget"]}
          ],
          "component_relationships": [], "claims": [], "uncertainties": []
        }
        """)
        let importer = SemanticImporter(store: store)
        _ = try importer.ingest(candidateURL: candidateURL, metaURL: nil, run: run, now: "t0")

        let symbol = try XCTUnwrap(store.symbol(runId: run.id, anchor: "pkg/a.py::Widget"))
        let highConfId = try store.db.dbQueue.read { dbc in
            try ComponentRecord.filter(Column("name") == "HighConf").fetchOne(dbc)?.id
        }
        XCTAssertEqual(symbol.componentId, highConfId)
    }

    func testIngestPersistsDiagnosticsNotJustTheInMemoryOutcome() throws {
        let store = try analyzed()
        let run = try XCTUnwrap(store.latestRun(commitHash: nil))
        let candidateURL = try writeCandidate("""
        {
          "schema_version": "phase2.v1",
          "components": [
            {"name": "Widgets", "members": ["pkg/a.py::Widget"]},
            {"name": "Widgets", "members": ["pkg/b.py"]}
          ],
          "component_relationships": [], "claims": [], "uncertainties": []
        }
        """)
        let importer = SemanticImporter(store: store)
        _ = try importer.ingest(candidateURL: candidateURL, metaURL: nil, run: run, now: "t0")

        try store.db.dbQueue.read { dbc in
            let diags = try DiagnosticRecord.filter(Column("stage") == "semantic_ingest").fetchAll(dbc)
            XCTAssertTrue(diags.contains { $0.code == "DUPLICATE_COMPONENT" && $0.message.contains("Widgets") })
        }
    }

    private func writeMeta(_ json: String) throws -> URL {
        let dir = try TempDir(); keepAlive.append(dir)
        try dir.write("meta.json", json)
        return URL(fileURLWithPath: dir.path("meta.json"))
    }

    // MARK: - fixtures

    private static let validJSON = """
    {
      "schema_version": "phase2.v1",
      "components": [{
        "name": "Widgets", "description": "Widget stuff.", "architectural_role": "core",
        "members": ["pkg/a.py::Widget"]
      }],
      "component_relationships": [],
      "claims": [{
        "claim_type": "INTERPRETATION", "statement": "Widget exists.",
        "evidence": ["pkg/a.py::Widget"], "confidence": "high"
      }],
      "uncertainties": ["Whether Widget.run always returns 1."]
    }
    """
}
