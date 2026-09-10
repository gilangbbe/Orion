import XCTest
import GRDB
@testable import OrionCodeIntel

/// Docs/16 M4: `RevisionDiffer` actually wired into `SemanticImporter.ingest()`/`.ingestAnswer()`
/// — unlike `RevisionDifferTests` (M2/M3, which call `RevisionDiffer` directly against
/// hand-built fixtures), these tests go through the real, full ingestion pipeline twice/three
/// times against one real analyzed repo, confirming the actual wiring produces real
/// `model_revisions`/`model_revision_entries` rows, not just that the differ's own logic is
/// correct in isolation.
final class RevisionDifferWiringTests: XCTestCase {

    private var keepAlive: [TempDir] = []

    /// Same fixture shape as `SemanticImporterTests`/`AgentAnswerImporterTests`: `pkg/a.py`
    /// imports `pkg/b.py` (a real, confirmable edge); `pkg/c.py::Gamma` has no relationship to
    /// either.
    private func analyzed() throws -> (store: Store, run: AnalysisRunRecord) {
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
        let store = Store(db)
        let run = try XCTUnwrap(store.latestRun(commitHash: nil))
        return (store, run)
    }

    private func writeCandidate(_ json: String) throws -> URL {
        let dir = try TempDir(); keepAlive.append(dir)
        try dir.write("candidate.json", json)
        return URL(fileURLWithPath: dir.path("candidate.json"))
    }

    // MARK: - `ingest()` wiring

    func testFirstIngestWithNoUncertaintiesWritesNoModelRevision() throws {
        let (store, run) = try analyzed()
        let candidateURL = try writeCandidate("""
        {
          "schema_version": "phase2.v1",
          "components": [{"name": "Alpha", "members": ["pkg/a.py"]}],
          "component_relationships": [], "claims": [], "uncertainties": []
        }
        """)
        let importer = SemanticImporter(store: store)
        _ = try importer.ingest(candidateURL: candidateURL, metaURL: nil, run: run, now: "t0")

        try store.db.dbQueue.read { dbc in
            XCTAssertEqual(try ModelRevisionRecord.fetchCount(dbc), 0)
        }
    }

    func testSecondIngestOfANewComponentWritesOneModelRevisionWithOneAddedEntry() throws {
        let (store, run) = try analyzed()
        let importer = SemanticImporter(store: store)

        _ = try importer.ingest(
            candidateURL: try writeCandidate("""
            {"schema_version": "phase2.v1",
             "components": [{"name": "Alpha", "members": ["pkg/a.py"]}],
             "component_relationships": [], "claims": [], "uncertainties": []}
            """), metaURL: nil, run: run, now: "t0")

        _ = try importer.ingest(
            candidateURL: try writeCandidate("""
            {"schema_version": "phase2.v1",
             "components": [
               {"name": "Alpha", "members": ["pkg/a.py"]},
               {"name": "Beta", "members": ["pkg/b.py"]}
             ],
             "component_relationships": [], "claims": [], "uncertainties": []}
            """), metaURL: nil, run: run, now: "t1")

        let revisions = try store.modelRevisions(repositoryId: run.repositoryId)
        XCTAssertEqual(revisions.count, 1)
        let revision = try XCTUnwrap(revisions.first)
        XCTAssertEqual(revision.revisionNumber, 1)
        XCTAssertNil(revision.previousRevision)
        XCTAssertTrue(revision.changeSummary.contains("1 component added"))

        let entries = try store.modelRevisionEntries(modelRevisionId: revision.id)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].entityType, ModelRevisionEntityType.component.rawValue)
        XCTAssertEqual(entries[0].changeType, ModelRevisionChangeType.added.rawValue)
        XCTAssertEqual(entries[0].subjectLabel, "Beta")
    }

    func testThirdIngestChainsRevisionNumberAndPreviousRevision() throws {
        let (store, run) = try analyzed()
        let importer = SemanticImporter(store: store)

        _ = try importer.ingest(
            candidateURL: try writeCandidate("""
            {"schema_version": "phase2.v1",
             "components": [{"name": "Alpha", "members": ["pkg/a.py"]}],
             "component_relationships": [], "claims": [], "uncertainties": []}
            """), metaURL: nil, run: run, now: "t0")
        // Second ingest: Beta added -> the first real revision (revision_number 1).
        _ = try importer.ingest(
            candidateURL: try writeCandidate("""
            {"schema_version": "phase2.v1",
             "components": [
               {"name": "Alpha", "members": ["pkg/a.py"]}, {"name": "Beta", "members": ["pkg/b.py"]}
             ],
             "component_relationships": [], "claims": [], "uncertainties": []}
            """), metaURL: nil, run: run, now: "t1")
        // Third ingest: Gamma added -> the second real revision (revision_number 2), chained.
        _ = try importer.ingest(
            candidateURL: try writeCandidate("""
            {"schema_version": "phase2.v1",
             "components": [
               {"name": "Alpha", "members": ["pkg/a.py"]}, {"name": "Beta", "members": ["pkg/b.py"]},
               {"name": "Gamma", "members": ["pkg/c.py"]}
             ],
             "component_relationships": [], "claims": [], "uncertainties": []}
            """), metaURL: nil, run: run, now: "t2")

        let revisions = try store.modelRevisions(repositoryId: run.repositoryId)
        XCTAssertEqual(revisions.count, 2)
        // Newest first (Store.modelRevisions' own ordering).
        XCTAssertEqual(revisions[0].revisionNumber, 2)
        XCTAssertEqual(revisions[1].revisionNumber, 1)
        XCTAssertEqual(revisions[0].previousRevision, revisions[1].id)
        XCTAssertNil(revisions[1].previousRevision)
    }

    // MARK: - `ingestAnswer()` wiring

    func testIngestAnswerWritesModelRevisionForAGenuinelyNewClaim() throws {
        let (store, run) = try analyzed()
        let importer = SemanticImporter(store: store)

        _ = try importer.ingestAnswer(
            candidateData: Data("""
            {"schema_version": "phase3.v1", "answer": "Widget.run in a.py returns the value 1.",
             "claims": [{"claim_type": "INTERPRETATION", "statement": "Widget.run returns 1.",
                         "evidence": ["pkg/a.py"], "confidence": "high"}],
             "uncertainties": []}
            """.utf8),
            meta: nil, question: "What does Widget.run do?", run: run, now: "t0")

        try store.db.dbQueue.read { dbc in
            // The very first investigation for this repository -- nothing to diff against yet.
            XCTAssertEqual(try ModelRevisionRecord.fetchCount(dbc), 0)
        }

        _ = try importer.ingestAnswer(
            candidateData: Data("""
            {"schema_version": "phase3.v1", "answer": "b.py defines a module-level constant VALUE.",
             "claims": [{"claim_type": "INTERPRETATION", "statement": "b.py defines VALUE.",
                         "evidence": ["pkg/b.py"], "confidence": "high"}],
             "uncertainties": []}
            """.utf8),
            meta: nil, question: "What does b.py define?", run: run, now: "t1")

        let revisions = try store.modelRevisions(repositoryId: run.repositoryId)
        XCTAssertEqual(revisions.count, 1)
        let entries = try store.modelRevisionEntries(modelRevisionId: revisions[0].id)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].entityType, ModelRevisionEntityType.claim.rawValue)
        XCTAssertEqual(entries[0].changeType, ModelRevisionChangeType.added.rawValue)
    }

    func testAmbiguousClaimMatchPersistsAModelRevisionStageDiagnostic() throws {
        let (store, run) = try analyzed()
        let importer = SemanticImporter(store: store)

        _ = try importer.ingestAnswer(
            candidateData: Data("""
            {"schema_version": "phase3.v1", "answer": "First answer citing a.py and b.py.",
             "claims": [{"claim_type": "INTERPRETATION", "statement": "AB claim.",
                         "evidence": ["pkg/a.py", "pkg/b.py"], "confidence": "high"}],
             "uncertainties": []}
            """.utf8),
            meta: nil, question: "Q1", run: run, now: "t0")

        _ = try importer.ingestAnswer(
            candidateData: Data("""
            {"schema_version": "phase3.v1", "answer": "Second answer citing a.py and c.py.",
             "claims": [{"claim_type": "INTERPRETATION", "statement": "AC claim.",
                         "evidence": ["pkg/a.py", "pkg/c.py"], "confidence": "high"}],
             "uncertainties": []}
            """.utf8),
            meta: nil, question: "Q2", run: run, now: "t1")

        // Overlaps both prior claims equally: jaccard({a,b},{a,b,c}) = jaccard({a,c},{a,b,c}) = 2/3.
        _ = try importer.ingestAnswer(
            candidateData: Data("""
            {"schema_version": "phase3.v1", "answer": "Third answer citing a.py, b.py and c.py.",
             "claims": [{"claim_type": "INTERPRETATION", "statement": "ABC claim.",
                         "evidence": ["pkg/a.py", "pkg/b.py", "pkg/c.py"], "confidence": "high"}],
             "uncertainties": []}
            """.utf8),
            meta: nil, question: "Q3", run: run, now: "t2")

        let diagnostics = try store.diagnostics(runId: run.id)
            .filter { $0.stage == "model_revision" }
        XCTAssertEqual(diagnostics.count, 1)
        XCTAssertEqual(diagnostics[0].code, "CLAIM_DIFF_AMBIGUOUS")
        XCTAssertEqual(diagnostics[0].severity, "info")
    }

    // MARK: - `backfillModelRevisions` (M6)

    /// Simulates a repository investigated *before* Phase 6 shipped: two real architecture
    /// investigations inserted directly via `Store` (bypassing `ingest()` entirely, since M4's
    /// wiring means every real `ingest()` call already tries to write a revision) -- exactly the
    /// shape `orion-index revisions --backfill` (§7) exists to retroactively cover.
    func testBackfillComputesRevisionsForPreExistingInvestigationHistory() throws {
        let (store, run) = try analyzed()

        let inv1 = InvestigationRecord(
            id: "inv1", repositoryId: run.repositoryId, commitHash: run.commitHash, runId: run.id,
            question: InvestigationRecord.architectureQuestionMarker, complexity: "high",
            outcome: "verified", createdAt: "2020-01-01T00:00:00Z")
        try store.insertInvestigation(inv1)
        try store.insertComponents([ComponentRecord(
            id: "c1", repositoryId: run.repositoryId, commitHash: run.commitHash, runId: run.id,
            investigationId: "inv1", name: "Alpha", description: nil, architecturalRole: nil,
            confidence: 0.9, confidenceTier: "high", status: "active",
            epistemicType: "INTERPRETATION", provenance: "claude_code"
        )])

        let inv2 = InvestigationRecord(
            id: "inv2", repositoryId: run.repositoryId, commitHash: run.commitHash, runId: run.id,
            question: InvestigationRecord.architectureQuestionMarker, complexity: "high",
            outcome: "verified", createdAt: "2020-01-02T00:00:00Z")
        try store.insertInvestigation(inv2)
        try store.insertComponents([
            ComponentRecord(
                id: "c1b", repositoryId: run.repositoryId, commitHash: run.commitHash, runId: run.id,
                investigationId: "inv2", name: "Alpha", description: nil, architecturalRole: nil,
                confidence: 0.9, confidenceTier: "high", status: "active",
                epistemicType: "INTERPRETATION", provenance: "claude_code"),
            ComponentRecord(
                id: "c2", repositoryId: run.repositoryId, commitHash: run.commitHash, runId: run.id,
                investigationId: "inv2", name: "Beta", description: nil, architecturalRole: nil,
                confidence: 0.9, confidenceTier: "high", status: "active",
                epistemicType: "INTERPRETATION", provenance: "claude_code"),
        ])

        XCTAssertEqual(try store.modelRevisions(repositoryId: run.repositoryId).count, 0)

        let created = try SemanticImporter(store: store)
            .backfillModelRevisions(investigations: [inv1, inv2], run: run)

        // inv1 is the repo's first investigation -- nothing to diff against (§9 Risk #5), so it
        // produces none; inv2 adds "Beta" -> exactly one revision.
        XCTAssertEqual(created, 1)
        let revisions = try store.modelRevisions(repositoryId: run.repositoryId)
        XCTAssertEqual(revisions.count, 1)
        // Dated to the investigation's own createdAt, not "now" -- the whole point of backfilling.
        XCTAssertEqual(revisions[0].createdAt, "2020-01-02T00:00:00Z")
        XCTAssertEqual(revisions[0].triggeringInvestigationId, "inv2")

        let entries = try store.modelRevisionEntries(modelRevisionId: revisions[0].id)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].subjectLabel, "Beta")
        XCTAssertEqual(entries[0].changeType, ModelRevisionChangeType.added.rawValue)
    }

    /// The real, entries-aware coverage check `orion-index revisions --backfill` uses (§7) --
    /// "covered" means a *structured* revision exists (>= 1 `model_revision_entries` row), not
    /// just any `model_revisions` row at all. Shared here so both tests below exercise the exact
    /// production logic, not a simplified stand-in for it.
    private func investigationsNeedingBackfill(
        store: Store, run: AnalysisRunRecord
    ) throws -> [InvestigationRecord] {
        var covered = Set<String>()
        for revision in try store.modelRevisions(repositoryId: run.repositoryId) {
            guard let triggering = revision.triggeringInvestigationId else { continue }
            if try !store.modelRevisionEntries(modelRevisionId: revision.id).isEmpty {
                covered.insert(triggering)
            }
        }
        return try store.investigations(repositoryId: run.repositoryId)
            .filter { !covered.contains($0.id) }
    }

    func testBackfillSkipsInvestigationsAlreadyCoveredWhenCallerFiltersThem() throws {
        // `backfillModelRevisions` itself doesn't re-check coverage (its own doc comment is
        // explicit about that) -- this confirms the caller-side filter correctly identifies an
        // already (really) covered investigation, the actual mechanism that keeps a second
        // `--backfill` invocation a safe no-op.
        let (store, run) = try analyzed()
        let importer = SemanticImporter(store: store)
        _ = try importer.ingest(
            candidateURL: writeCandidate("""
            {"schema_version": "phase2.v1",
             "components": [{"name": "Alpha", "members": ["pkg/a.py"]}],
             "component_relationships": [], "claims": [], "uncertainties": ["Whether Alpha is complete."]}
            """), metaURL: nil, run: run, now: "t0")
        _ = try importer.ingest(
            candidateURL: writeCandidate("""
            {"schema_version": "phase2.v1",
             "components": [
               {"name": "Alpha", "members": ["pkg/a.py"]}, {"name": "Beta", "members": ["pkg/b.py"]}
             ],
             "component_relationships": [], "claims": [], "uncertainties": []}
            """), metaURL: nil, run: run, now: "t1")

        // Both investigations were already covered live at ingestion time (the first raised an
        // uncertainty -> `.added` per §9's amended Risk #5; the second added "Beta") -- nothing
        // left to backfill, confirming a second `--backfill` run is a real no-op, not just an
        // empty-by-accident result.
        let toBackfill = try investigationsNeedingBackfill(store: store, run: run)
        XCTAssertTrue(toBackfill.isEmpty)
        let createdAgain = try importer.backfillModelRevisions(investigations: toBackfill, run: run)
        XCTAssertEqual(createdAgain, 0)
        XCTAssertEqual(try store.modelRevisions(repositoryId: run.repositoryId).count, 2)
    }

    /// A real bug found against real data (Docs/16 M6): a repository ingested under Phase 2/3's
    /// old, pre-Phase-6 unconditional-write behavior already has one coarse, entry-less
    /// `model_revisions` row per investigation -- each with a real `triggering_investigation_id`
    /// already set. A naive `Set(modelRevisions.compactMap(\.triggeringInvestigationId))`
    /// coverage check (this command's own first draft) reads every one of those as "already
    /// backfilled" and silently no-ops on exactly the databases `--backfill` exists to help --
    /// reproduced here by hand-inserting one such legacy row, matching the shape found live
    /// against the real vendored-Starlette research database.
    func testLegacyEntrylessRevisionIsNotTreatedAsCoverage() throws {
        let (store, run) = try analyzed()
        let inv = InvestigationRecord(
            id: "inv-legacy", repositoryId: run.repositoryId, commitHash: run.commitHash,
            runId: run.id, question: InvestigationRecord.architectureQuestionMarker,
            complexity: "high", outcome: "verified", createdAt: "2020-01-01T00:00:00Z")
        try store.insertInvestigation(inv)
        try store.insertComponents([ComponentRecord(
            id: "c-legacy", repositoryId: run.repositoryId, commitHash: run.commitHash,
            runId: run.id, investigationId: "inv-legacy", name: "Alpha", description: nil,
            architecturalRole: nil, confidence: 0.9, confidenceTier: "high", status: "active",
            epistemicType: "INTERPRETATION", provenance: "claude_code"
        )])
        // Phase 2/3's own old, coarse, entry-less write -- exactly what a pre-Phase-6 `ingest()`
        // call actually persisted.
        try store.insertModelRevision(ModelRevisionRecord(
            id: "rev-legacy", repositoryId: run.repositoryId, previousRevision: nil,
            changeSummary: "Ingested 1 components, 0 component_relationships, 0 claims from "
                + "investigation inv-legacy.",
            triggeringInvestigationId: "inv-legacy", createdAt: "2020-01-01T00:00:00Z"))

        let toBackfill = try investigationsNeedingBackfill(store: store, run: run)
        XCTAssertEqual(toBackfill.map(\.id), ["inv-legacy"])

        // Backfilling it for real produces nothing new here (inv-legacy is this repo's first and
        // only investigation, so there's nothing to diff against, §9 Risk #5) -- the point of
        // this test is that it was correctly offered up for backfill at all, not what backfilling
        // a lone first investigation happens to produce.
        let created = try SemanticImporter(store: store)
            .backfillModelRevisions(investigations: toBackfill, run: run)
        XCTAssertEqual(created, 0)
    }

    /// A second real bug found against the same real vendored-Starlette research database, in
    /// the same backfill run as `testLegacyEntrylessRevisionIsNotTreatedAsCoverage`'s own finding
    /// (Docs/16 M6): with **more than one** pre-existing legacy coarse row, backfilling
    /// investigations in their own chronological order produced *four* new revisions that all
    /// chained onto the *same* predecessor (whichever legacy row happened to have the latest
    /// `created_at` across the whole table, whether or not it actually preceded the investigation
    /// being processed) and all landed on the identical `revision_number` -- confirmed live
    /// against the real database before this was understood, then reproduced minimally here.
    /// Root cause: `writeModelRevision` used to ask "what's the single most-recently-created row
    /// in `model_revisions`," which only equals "the true predecessor" when rows are written in
    /// real chronological order -- true for live ingestion, false during a backfill that inserts
    /// out of step with rows already sitting in the table. Fixed by walking the investigation
    /// history itself (`previousRevision(before:repositoryId:)`) instead of the revisions table's
    /// own insertion order.
    func testBackfillProducesAProperlyChainedSequenceEvenWithOutOfOrderLegacyRevisions() throws {
        let (store, run) = try analyzed()

        func legacyComponent(_ id: String, investigationId: String, name: String) -> ComponentRecord {
            ComponentRecord(
                id: id, repositoryId: run.repositoryId, commitHash: run.commitHash, runId: run.id,
                investigationId: investigationId, name: name, description: nil,
                architecturalRole: nil, confidence: 0.9, confidenceTier: "high", status: "active",
                epistemicType: "INTERPRETATION", provenance: "claude_code")
        }

        // Three investigations, each already carrying a legacy coarse revision (matching the real
        // database's own shape: every one of Starlette's 4 real investigations had one) -- Alpha
        // only, then +Beta, then +Beta+Gamma.
        let investigations = (1...3).map { n in
            InvestigationRecord(
                id: "inv\(n)", repositoryId: run.repositoryId, commitHash: run.commitHash,
                runId: run.id, question: InvestigationRecord.architectureQuestionMarker,
                complexity: "high", outcome: "verified", createdAt: "2020-01-0\(n)T00:00:00Z")
        }
        for inv in investigations { try store.insertInvestigation(inv) }

        try store.insertComponents([legacyComponent("c1", investigationId: "inv1", name: "Alpha")])
        try store.insertComponents([
            legacyComponent("c2a", investigationId: "inv2", name: "Alpha"),
            legacyComponent("c2b", investigationId: "inv2", name: "Beta"),
        ])
        try store.insertComponents([
            legacyComponent("c3a", investigationId: "inv3", name: "Alpha"),
            legacyComponent("c3b", investigationId: "inv3", name: "Beta"),
            legacyComponent("c3c", investigationId: "inv3", name: "Gamma"),
        ])
        for inv in investigations {
            try store.insertModelRevision(ModelRevisionRecord(
                id: "legacy-\(inv.id)", repositoryId: run.repositoryId, previousRevision: nil,
                changeSummary: "legacy coarse row for \(inv.id)",
                triggeringInvestigationId: inv.id, createdAt: inv.createdAt))
        }

        // Confirms the setup actually reproduces the hazard this test exists to catch: before the
        // fix, `store.latestModelRevision(repositoryId:)` alone would resolve to inv3's own
        // legacy row here, regardless of which investigation is being backfilled.
        XCTAssertEqual(
            try store.latestModelRevision(repositoryId: run.repositoryId)?.id, "legacy-inv3")

        let created = try SemanticImporter(store: store)
            .backfillModelRevisions(investigations: investigations, run: run)

        // inv1 is first-ever -> nothing to diff against; inv2 (+Beta) and inv3 (+Gamma) each
        // produce one real revision.
        XCTAssertEqual(created, 2)

        let allRevisions = try store.modelRevisions(repositoryId: run.repositoryId)
        let newInv2Revision = try XCTUnwrap(
            allRevisions.first {
                $0.triggeringInvestigationId == "inv2" && $0.id != "legacy-inv2"
            })
        let newInv3Revision = try XCTUnwrap(
            allRevisions.first {
                $0.triggeringInvestigationId == "inv3" && $0.id != "legacy-inv3"
            })

        // The real fix, asserted directly: inv3's new revision chains onto inv2's *new* revision
        // -- never onto inv3's own pre-existing legacy row, and never onto some unrelated later
        // timestamp purely because it happened to be the last row physically inserted.
        XCTAssertEqual(newInv3Revision.previousRevision, newInv2Revision.id)
        // And a strictly increasing sequence, not two revisions landing on the same number.
        XCTAssertEqual(newInv3Revision.revisionNumber, newInv2Revision.revisionNumber + 1)
    }
}
