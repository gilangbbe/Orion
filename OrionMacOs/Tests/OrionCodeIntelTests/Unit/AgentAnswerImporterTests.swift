import XCTest
import GRDB
@testable import OrionCodeIntel

/// Docs/12_phase3_mlx_agent.md "Claude delegation (L3)": `SemanticImporter.ingestAnswer` —
/// the M3 entry point for one L3 question's answer. Only tests the schema/scope differences
/// from `ingest()` (Phase 2) directly; the shared claim-evidence-resolution and
/// consistency-check logic is already covered by `SemanticImporterTests` and was refactored,
/// not rewritten, to be reused here.
final class AgentAnswerImporterTests: XCTestCase {

    private var keepAlive: [TempDir] = []

    /// Same fixture as `SemanticImporterTests`: `pkg/a.py` imports `pkg/b.py` (a real,
    /// confirmable edge); `pkg/c.py::Gamma` has no relationship to either (the "unconnected"
    /// case for the claim-contradiction check).
    private func analyzed() throws -> Store {
        let repo = try TempDir()
        keepAlive.append(repo)
        let git = GitRunner(repoPath: repo.url)
        _ = try git.run(["init", "--quiet", "-b", "main"])
        _ = try git.run(["config", "user.email", "t@e.com"])
        _ = try git.run(["config", "user.name", "T"])
        try repo.write("pkg/__init__.py", "")
        try repo.write(
            "pkg/a.py", "from pkg import b\n\nclass Widget:\n    def run(self):\n        return 1\n")
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

    private func decodeFindings(_ json: String) throws -> AgentAnswerFindings {
        try JSONDecoder().decode(AgentAnswerFindings.self, from: Data(json.utf8))
    }

    // MARK: step 1 — schema

    func testValidateAnswerSchemaAcceptsWellFormedCandidate() throws {
        let findings = try decodeFindings(Self.validJSON)
        let importer = SemanticImporter(store: Store(try OrionDatabase(inMemory: true)))
        XCTAssertEqual(importer.validateAnswerSchema(findings), [])
    }

    func testValidateAnswerSchemaRejectsWrongVersion() throws {
        let findings = try decodeFindings(
            Self.validJSON.replacingOccurrences(of: "\"phase3.v1\"", with: "\"phase2.v1\""))
        let importer = SemanticImporter(store: Store(try OrionDatabase(inMemory: true)))
        XCTAssertTrue(importer.validateAnswerSchema(findings).contains { $0.contains("schema_version") })
    }

    func testValidateAnswerSchemaRejectsEmptyAnswer() throws {
        let json = """
            {"schema_version": "phase3.v1", "answer": "  ", "claims": [], "uncertainties": []}
            """
        let findings = try decodeFindings(json)
        let importer = SemanticImporter(store: Store(try OrionDatabase(inMemory: true)))
        XCTAssertTrue(importer.validateAnswerSchema(findings).contains { $0.contains("answer is empty") })
    }

    /// Found live (Docs/12 M5): a real `claude` CLI investigation, after dozens of real turns
    /// and real cost, twice returned the literal 4-character answer "test" -- schema-conformant
    /// (non-empty) but obviously not a real answer. `minLength: 1` alone doesn't catch this.
    func testValidateAnswerSchemaRejectsSuspiciouslyShortAnswer() throws {
        let json = """
            {"schema_version": "phase3.v1", "answer": "test", "claims": [], "uncertainties": []}
            """
        let findings = try decodeFindings(json)
        let importer = SemanticImporter(store: Store(try OrionDatabase(inMemory: true)))
        XCTAssertTrue(importer.validateAnswerSchema(findings).contains { $0.contains("too short") })
    }

    func testValidateAnswerSchemaRejectsBadConfidence() throws {
        let json = """
            {"schema_version": "phase3.v1", "answer": "x",
             "claims": [{"claim_type": "INTERPRETATION", "statement": "s", "evidence": [], "confidence": "extreme"}],
             "uncertainties": []}
            """
        let findings = try decodeFindings(json)
        let importer = SemanticImporter(store: Store(try OrionDatabase(inMemory: true)))
        XCTAssertTrue(importer.validateAnswerSchema(findings).contains { $0.contains("confidence") })
    }

    func testDecodeRejectsUnknownClaimType() {
        // FACT/CONTRADICTED are not decodable claim_type values -- Claude never self-tags them,
        // same rule as Phase 2's SemanticClaimInput (reused here directly).
        let json = """
            {"schema_version":"phase3.v1","answer":"x",
             "claims":[{"claim_type":"FACT","statement":"x","evidence":[],"confidence":"high"}],
             "uncertainties":[]}
            """
        XCTAssertThrowsError(try decodeFindings(json))
    }

    // MARK: ingestAnswer — full pipeline

    func testIngestAnswerPersistsCleanAnswerAsVerified() throws {
        let store = try analyzed()
        let run = try XCTUnwrap(store.latestRun(commitHash: nil))
        let candidate = Data("""
            {
              "schema_version": "phase3.v1",
              "answer": "Widget.run in a.py returns 1; a.py also imports b.py.",
              "claims": [{
                "claim_type": "INTERPRETATION", "statement": "a.py imports b.py.",
                "evidence": ["pkg/a.py", "pkg/b.py"], "confidence": "high"
              }],
              "uncertainties": []
            }
            """.utf8)
        let importer = SemanticImporter(store: store)
        let outcome = try importer.ingestAnswer(
            candidateData: candidate, meta: nil, question: "What does Widget.run do?",
            run: run, now: "t0")

        XCTAssertEqual(outcome.investigation.outcome, InvestigationOutcome.verified.rawValue)
        XCTAssertEqual(outcome.investigation.question, "What does Widget.run do?")
        XCTAssertEqual(outcome.investigation.complexity, "high")
        XCTAssertEqual(outcome.consistent.claims.count, 1)
        XCTAssertEqual(outcome.consistent.claims.first?.claimType, .interpretation)
    }

    func testIngestAnswerNeverTouchesComponentTables() throws {
        let store = try analyzed()
        let run = try XCTUnwrap(store.latestRun(commitHash: nil))
        let candidate = Data("""
            {"schema_version": "phase3.v1", "answer": "A placeholder answer text for this test.",
             "claims": [{"claim_type": "INTERPRETATION", "statement": "s",
                         "evidence": ["pkg/a.py"], "confidence": "high"}],
             "uncertainties": []}
            """.utf8)
        let importer = SemanticImporter(store: store)
        let outcome = try importer.ingestAnswer(
            candidateData: candidate, meta: nil, question: "q", run: run, now: "t0")

        XCTAssertTrue(outcome.consistent.components.isEmpty)
        XCTAssertTrue(outcome.consistent.componentRelationships.isEmpty)
        try store.db.dbQueue.read { dbc in
            XCTAssertEqual(try ComponentRecord.fetchCount(dbc), 0)
            XCTAssertEqual(try ComponentRelationshipRecord.fetchCount(dbc), 0)
        }
    }

    func testIngestAnswerReclassifiesUnconnectedMultiEvidenceClaimAsContradicted() throws {
        let store = try analyzed()
        let run = try XCTUnwrap(store.latestRun(commitHash: nil))
        // pkg/a.py and pkg/c.py::Gamma share no Phase 1 relationship.
        let candidate = Data("""
            {"schema_version": "phase3.v1", "answer": "A placeholder answer text for this test.",
             "claims": [{"claim_type": "INTERPRETATION", "statement": "unrelated claim",
                         "evidence": ["pkg/a.py", "pkg/c.py::Gamma"], "confidence": "high"}],
             "uncertainties": []}
            """.utf8)
        let importer = SemanticImporter(store: store)
        let outcome = try importer.ingestAnswer(
            candidateData: candidate, meta: nil, question: "q", run: run, now: "t0")

        XCTAssertEqual(outcome.investigation.outcome, InvestigationOutcome.partiallyVerified.rawValue)
        XCTAssertEqual(outcome.consistent.claims.first?.claimType, .contradicted)
    }

    func testIngestAnswerDropsUnresolvedAnchorAndStaysPartial() throws {
        let store = try analyzed()
        let run = try XCTUnwrap(store.latestRun(commitHash: nil))
        let candidate = Data("""
            {"schema_version": "phase3.v1", "answer": "A placeholder answer text for this test.",
             "claims": [
               {"claim_type": "INTERPRETATION", "statement": "good", "evidence": ["pkg/a.py"], "confidence": "high"},
               {"claim_type": "INTERPRETATION", "statement": "bad", "evidence": ["pkg/nope.py::Nope"], "confidence": "high"}
             ],
             "uncertainties": []}
            """.utf8)
        let importer = SemanticImporter(store: store)
        let outcome = try importer.ingestAnswer(
            candidateData: candidate, meta: nil, question: "q", run: run, now: "t0")

        XCTAssertEqual(outcome.investigation.outcome, InvestigationOutcome.partiallyVerified.rawValue)
        XCTAssertEqual(outcome.consistent.claims.count, 1)
        XCTAssertEqual(outcome.consistent.droppedClaims, ["bad"])
    }

    func testIngestAnswerWithNoClaimsOrUncertaintiesIsVerified() throws {
        // A pure prose answer -- nothing to substantiate, so nothing failed to substantiate.
        let store = try analyzed()
        let run = try XCTUnwrap(store.latestRun(commitHash: nil))
        let candidate = Data("""
            {"schema_version": "phase3.v1", "answer": "Just a plain answer, no claims.",
             "claims": [], "uncertainties": []}
            """.utf8)
        let importer = SemanticImporter(store: store)
        let outcome = try importer.ingestAnswer(
            candidateData: candidate, meta: nil, question: "q", run: run, now: "t0")

        XCTAssertEqual(outcome.investigation.outcome, InvestigationOutcome.verified.rawValue)
        XCTAssertTrue(outcome.consistent.claims.isEmpty)
    }

    func testIngestAnswerUncertaintyBecomesUnknownClaim() throws {
        let store = try analyzed()
        let run = try XCTUnwrap(store.latestRun(commitHash: nil))
        let candidate = Data("""
            {"schema_version": "phase3.v1", "answer": "A placeholder answer text for this test.",
             "claims": [], "uncertainties": ["Not sure how X handles concurrency."]}
            """.utf8)
        let importer = SemanticImporter(store: store)
        let outcome = try importer.ingestAnswer(
            candidateData: candidate, meta: nil, question: "q", run: run, now: "t0")

        XCTAssertEqual(outcome.consistent.claims.count, 1)
        XCTAssertEqual(outcome.consistent.claims.first?.claimType, .unknown)
        XCTAssertEqual(outcome.investigation.outcome, InvestigationOutcome.verified.rawValue)
    }

    func testIngestAnswerSchemaMismatchStillPersistsRejectedInvestigation() throws {
        let store = try analyzed()
        let run = try XCTUnwrap(store.latestRun(commitHash: nil))
        let candidate = Data("""
            {"schema_version": "phase1.v9", "answer": "x", "claims": [], "uncertainties": []}
            """.utf8)
        let importer = SemanticImporter(store: store)

        XCTAssertThrowsError(
            try importer.ingestAnswer(
                candidateData: candidate, meta: nil, question: "q", run: run, now: "t0")
        ) { error in
            guard case SemanticImportError.schemaInvalid(_, let inv) = error else {
                return XCTFail("expected schemaInvalid, got \(error)")
            }
            XCTAssertEqual(inv.outcome, InvestigationOutcome.rejected.rawValue)
            XCTAssertEqual(inv.question, "q")
        }
    }

    func testIngestAnswerDecodeFailureStillPersistsRejectedInvestigation() throws {
        let store = try analyzed()
        let run = try XCTUnwrap(store.latestRun(commitHash: nil))
        let candidate = Data("not json at all".utf8)
        let importer = SemanticImporter(store: store)

        XCTAssertThrowsError(
            try importer.ingestAnswer(
                candidateData: candidate, meta: nil, question: "q", run: run, now: "t0")
        ) { error in
            guard case SemanticImportError.decodeFailed(_, let inv) = error else {
                return XCTFail("expected decodeFailed, got \(error)")
            }
            XCTAssertEqual(inv.outcome, InvestigationOutcome.rejected.rawValue)
        }
    }

    func testIngestAnswerCapturesMeta() throws {
        let store = try analyzed()
        let run = try XCTUnwrap(store.latestRun(commitHash: nil))
        let candidate = Data("""
            {"schema_version": "phase3.v1", "answer": "A placeholder answer text for this test.",
             "claims": [], "uncertainties": []}
            """.utf8)
        let meta = InvestigationMeta(
            modelUsed: "claude-sonnet-5", sessionId: "sess-42", numTurns: 12,
            totalCostUsd: 0.34, durationMs: 5000, toolsUsed: ["Read", "Grep", "Glob"])
        let importer = SemanticImporter(store: store)
        let outcome = try importer.ingestAnswer(
            candidateData: candidate, meta: meta, question: "q", run: run, now: "t0")

        XCTAssertEqual(outcome.investigation.modelUsed, "claude-sonnet-5")
        XCTAssertEqual(outcome.investigation.sessionId, "sess-42")
        XCTAssertEqual(outcome.investigation.numTurns, 12)
    }

    private static let validJSON = """
        {
          "schema_version": "phase3.v1",
          "answer": "A prose answer explaining the investigation's findings.",
          "claims": [{
            "claim_type": "INTERPRETATION", "statement": "s",
            "evidence": ["pkg/a.py"], "confidence": "high"
          }],
          "uncertainties": ["Something unverified."]
        }
        """
}
