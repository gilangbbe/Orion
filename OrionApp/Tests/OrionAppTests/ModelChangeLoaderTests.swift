import XCTest

@testable import Orion
import OrionCodeIntel

/// Docs/16_phase6_continuous_model_updates.md §8, M5: `ModelChangeLoader` against a real,
/// twice-ingested analyzed repo -- the same fixture pattern `ComponentDetailLoaderTests`/
/// `ArchitectureModelLoaderTests` already established, not hand-built `Store` rows (that's
/// `OrionMacOs`'s own `RevisionDifferTests`' job).
final class ModelChangeLoaderTests: XCTestCase {
    private func makeRepoRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ModelChangeLoaderTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func analyze(_ repoRoot: URL) throws -> URL {
        let outputDirectory = RepositorySession.outputDirectory(forRepoRoot: repoRoot)
        try FileManager.default.createDirectory(
            at: outputDirectory, withIntermediateDirectories: true)
        let database = try OrionDatabase(
            path: outputDirectory.appendingPathComponent("orion.db").path)
        _ = try AnalysisPipeline(database: database).run(
            AnalysisInput(repoPath: repoRoot, outputDirectory: outputDirectory, resolve: false))
        return outputDirectory
    }

    /// `now` defaults to the real current time, but every test in this file ingests more than
    /// once and needs strictly-increasing values instead -- `Timestamp.now()` is only
    /// second-resolution, and both `ArchitectureModelLoader`'s own investigation tie-break and
    /// (less critically) `RevisionDiffer`'s ordering assume real ordering between calls, not an
    /// exact tie (see `ComponentDetailLoaderTests`'s identical fix for the concrete failure this
    /// avoided).
    private func ingestSemanticFindings(
        _ json: String, into outputDirectory: URL, now: String = Timestamp.now()
    ) throws {
        let database = try OrionDatabase(
            path: outputDirectory.appendingPathComponent("orion.db").path)
        let store = Store(database)
        let run = try XCTUnwrap(store.latestRun(commitHash: nil))
        let candidateURL = outputDirectory.appendingPathComponent("semantic_findings.json")
        try json.write(to: candidateURL, atomically: true, encoding: .utf8)
        _ = try SemanticImporter(store: store).ingest(
            candidateURL: candidateURL, metaURL: nil, run: run, now: now)
    }

    func testEmptyWhenNoRevisionsYet() throws {
        let repoRoot = try makeRepoRoot()
        try "def foo(): pass\n".write(
            to: repoRoot.appendingPathComponent("a.py"), atomically: true, encoding: .utf8)
        let outputDirectory = try analyze(repoRoot)
        // A single ingest with no uncertainties is the repository's first investigation --
        // nothing to diff against yet (Docs/16 §9 Risk #5).
        try ingestSemanticFindings(
            """
            {"schema_version": "phase2.v1",
             "components": [{"name": "Core", "members": ["a.py::foo"]}],
             "component_relationships": [], "claims": [], "uncertainties": []}
            """, into: outputDirectory)

        XCTAssertEqual(try ModelChangeLoader.load(outputDirectory: outputDirectory), [])
        XCTAssertEqual(try ModelChangeLoader.revisionCount(outputDirectory: outputDirectory), 0)
    }

    /// A real bug, found live against a real repository with pre-Phase-6 history: `revisionCount`
    /// used to count every `model_revisions` row, including entry-less legacy ones from Phase
    /// 2/3's own old unconditional-write behavior (the same shape `orion-index revisions
    /// --backfill` exists to fill in, Docs/16 §11 M6) -- which never render as a card at all
    /// (`load()` correctly produces none for them), so the sidebar's badge could read e.g. "50"
    /// while the Model Changes screen itself showed "No model changes yet." Confirmed the fix
    /// directly: a hand-inserted legacy row must not count.
    func testRevisionCountExcludesLegacyEntrylessRevisions() throws {
        let repoRoot = try makeRepoRoot()
        try "def foo(): pass\n".write(
            to: repoRoot.appendingPathComponent("a.py"), atomically: true, encoding: .utf8)
        let outputDirectory = try analyze(repoRoot)
        let database = try OrionDatabase(
            path: outputDirectory.appendingPathComponent("orion.db").path)
        let store = Store(database)
        let run = try XCTUnwrap(store.latestRun(commitHash: nil))
        try store.insertInvestigation(InvestigationRecord(
            id: "inv-legacy", repositoryId: run.repositoryId, commitHash: run.commitHash,
            runId: run.id, question: InvestigationRecord.architectureQuestionMarker,
            complexity: "high", outcome: "verified", createdAt: "2020-01-01T00:00:00Z"))
        try store.insertModelRevision(ModelRevisionRecord(
            id: "rev-legacy", repositoryId: run.repositoryId, previousRevision: nil,
            changeSummary: "Ingested 0 components, 0 component_relationships, 0 claims from "
                + "investigation inv-legacy.",
            triggeringInvestigationId: "inv-legacy", createdAt: "2020-01-01T00:00:00Z"))

        XCTAssertEqual(try ModelChangeLoader.revisionCount(outputDirectory: outputDirectory), 0)
        XCTAssertEqual(try ModelChangeLoader.load(outputDirectory: outputDirectory), [])
    }

    /// Reproduces Docs/05 Stage 6's own worked example end to end, through the real loader: a
    /// direct relationship replaced by a chain through an intermediate component groups into one
    /// card (Docs/16 §8's own explicit instruction), not four disconnected rows.
    func testGroupsARemovedRelationshipAndItsReplacementChainIntoOneCard() throws {
        let repoRoot = try makeRepoRoot()
        try """
        def auth(): pass
        def persist(): pass
        def sess(): pass
        def store_(): pass
        def keychain(): pass
        """.write(to: repoRoot.appendingPathComponent("a.py"), atomically: true, encoding: .utf8)
        let outputDirectory = try analyze(repoRoot)

        try ingestSemanticFindings(
            """
            {"schema_version": "phase2.v1",
             "components": [
               {"name": "AuthService", "members": ["a.py::auth"]},
               {"name": "Persistence", "members": ["a.py::persist"]},
               {"name": "SessionManager", "members": ["a.py::sess"]},
               {"name": "SessionStore", "members": ["a.py::store_"]},
               {"name": "Keychain", "members": ["a.py::keychain"]}
             ],
             "component_relationships": [{"source": "AuthService", "target": "Persistence", "type": "depends_on"}],
             "claims": [], "uncertainties": []}
            """, into: outputDirectory, now: "t0")

        try ingestSemanticFindings(
            """
            {"schema_version": "phase2.v1",
             "components": [
               {"name": "AuthService", "members": ["a.py::auth"]},
               {"name": "Persistence", "members": ["a.py::persist"]},
               {"name": "SessionManager", "members": ["a.py::sess"]},
               {"name": "SessionStore", "members": ["a.py::store_"]},
               {"name": "Keychain", "members": ["a.py::keychain"]}
             ],
             "component_relationships": [
               {"source": "AuthService", "target": "SessionManager", "type": "depends_on"},
               {"source": "SessionManager", "target": "SessionStore", "type": "depends_on"},
               {"source": "SessionStore", "target": "Keychain", "type": "depends_on"}
             ],
             "claims": [], "uncertainties": []}
            """, into: outputDirectory, now: "t1")

        XCTAssertEqual(try ModelChangeLoader.revisionCount(outputDirectory: outputDirectory), 1)

        let cards = try ModelChangeLoader.load(outputDirectory: outputDirectory)
        // Three distinct *source* components appear across the 4 relationship entries
        // (AuthService: the removed edge + the first added one; SessionManager and SessionStore:
        // one added edge each as their own source) -- grouping-by-source (`ModelChangeLoader`'s
        // own documented scope limit) produces one card per source, not one unified chain card,
        // and specifically groups the removed edge together with the new edge sharing its source,
        // which is the concrete case Docs/16 §8 named directly.
        XCTAssertEqual(cards.count, 3)
        XCTAssertEqual(Set(cards.map(\.title)), ["AuthService", "SessionManager", "SessionStore"])

        let authCard = try XCTUnwrap(cards.first { $0.title == "AuthService" })
        XCTAssertTrue(authCard.before.contains("AuthService -> Persistence"))
        XCTAssertTrue(authCard.after.contains("AuthService -> SessionManager"))

        let sessionCard = try XCTUnwrap(cards.first { $0.title == "SessionManager" })
        XCTAssertTrue(sessionCard.after.contains("SessionManager -> SessionStore"))
        XCTAssertEqual(sessionCard.before, "—")  // nothing removed that was *about* SessionManager
    }

    func testClaimAndUncertaintyEntriesBecomeStandaloneCards() throws {
        let repoRoot = try makeRepoRoot()
        try "def foo(): pass\ndef bar(): pass\n".write(
            to: repoRoot.appendingPathComponent("a.py"), atomically: true, encoding: .utf8)
        let outputDirectory = try analyze(repoRoot)

        try ingestSemanticFindings(
            """
            {"schema_version": "phase2.v1",
             "components": [{"name": "Core", "members": ["a.py::foo"]}],
             "component_relationships": [],
             "claims": [{"claim_type": "INTERPRETATION", "statement": "foo does nothing.",
                         "evidence": ["a.py::foo"], "confidence": "high"}],
             "uncertainties": ["Whether bar is dead code."]}
            """, into: outputDirectory, now: "t0")

        try ingestSemanticFindings(
            """
            {"schema_version": "phase2.v1",
             "components": [{"name": "Core", "members": ["a.py::foo"]}],
             "component_relationships": [],
             "claims": [{"claim_type": "INTERPRETATION", "statement": "bar is unused.",
                         "evidence": ["a.py::bar"], "confidence": "high"}],
             "uncertainties": []}
            """, into: outputDirectory, now: "t1")

        let cards = try ModelChangeLoader.load(outputDirectory: outputDirectory)
        // 1 new claim ("bar is unused") + 1 uncertainty resolved one way or the other -- each its
        // own card (no shared "component" subject to group them under), no Core component card
        // at all (Core itself never changed between the two ingests). Titles now carry the change
        // type (§12 redesign) -- "Claim added" / "Open question no longer raised" -- not a bare
        // "Claim" / "Open question".
        XCTAssertTrue(cards.allSatisfy { $0.title.hasPrefix("Claim ") || $0.title.hasPrefix("Open question ") })
        XCTAssertTrue(cards.contains { $0.title == "Claim added" && $0.after.contains("bar is unused") })
        XCTAssertTrue(cards.contains { $0.title == "Open question no longer raised" })
        XCTAssertFalse(cards.contains { $0.title == "Core" })
    }
}
