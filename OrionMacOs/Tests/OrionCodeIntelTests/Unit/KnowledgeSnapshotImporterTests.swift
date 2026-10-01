import GRDB
import XCTest

@testable import OrionCodeIntel
@testable import OrionCore

/// Docs/19 M3: importing snapshots into the device library, and keeping the device's own learning
/// and asking across a re-import. The snapshots are real ones, built by `KnowledgeSnapshotBuilder`
/// from a hand-made Mac database and checkout.
final class KnowledgeSnapshotImporterTests: XCTestCase {
    private var dir: TempDir!
    private var repo: URL { dir.url.appendingPathComponent("demo", isDirectory: true) }
    private var library: LocalLibrary { LocalLibrary(root: dir.url.appendingPathComponent("library")) }
    private var importer: KnowledgeSnapshotImporter { KnowledgeSnapshotImporter(library: library) }
    private let appText = (1...30).map { "line \($0)" }.joined(separator: "\n")

    override func setUpWithError() throws {
        dir = try TempDir("orion-import-test")
        try dir.write("demo/pkg/app.py", appText)
    }

    override func tearDown() { dir = nil }

    // MARK: - Mac-side fixture

    /// One Mac analysis of `demo`: repository `repoId` at `commit`, run `runId`, with a component,
    /// a claim, concepts named `concepts`, and one verified question per concept (`q-<repoId>-<n>`).
    /// Ids that derive from the run (files, symbols, components) are prefixed by `runId`, the way a
    /// re-analysis at a new commit changes them.
    private func macSnapshot(
        name: String, repoId: String, commit: String, runId: String, concepts: [String],
        macRevision: Bool = false
    ) throws -> KnowledgeSnapshotBuilder.Output {
        let dbURL = dir.url.appendingPathComponent("mac-\(name)/orion.db")
        let db = try OrionDatabase(path: dbURL.path)
        let store = Store(db)
        let sha = KnowledgeSnapshotFormat.sha256Hex(Data(appText.utf8))
        try db.dbQueue.write { dbc in
            try RepositoryRecord(
                id: repoId, sourceURL: nil, localPath: repo.path, commitHash: commit, languages: ["python"],
                analysisStatus: .succeeded, createdAt: "t0", updatedAt: "t0"
            ).insert(dbc)
            try AnalysisRunRecord(
                id: runId, repositoryId: repoId, commitHash: commit, status: "succeeded", startedAt: "t0",
                orionVersion: "0.1.0", resolver: "none", grammarVersions: [:], toolVersions: [:], stageTimings: [:],
                fileCount: 1, symbolCount: 1, relationshipCount: 0, diagnosticCount: 0
            ).insert(dbc)
            try FileRecord(
                id: "\(runId)-f", repositoryId: repoId, commitHash: commit, runId: runId, path: "pkg/app.py",
                language: "python", sha256: sha, byteSize: 0, lineCount: 30, isTest: false, isPackageInit: false,
                parseOk: true
            ).insert(dbc)
            try SymbolRecord(
                id: "\(runId)-s", repositoryId: repoId, commitHash: commit, runId: runId, fileId: "\(runId)-f",
                name: "helper", qualifiedName: "helper", anchor: "pkg/app.py::helper", kind: "function",
                startLine: 20, startCol: 0, endLine: 22, endCol: 0, startByte: 0, endByte: 0, decorators: [],
                visibility: "public", isExported: true, epistemicType: "FACT"
            ).insert(dbc)
        }
        try store.insertInvestigation(InvestigationRecord(
            id: "\(runId)-inv", repositoryId: repoId, commitHash: commit, runId: runId,
            question: InvestigationRecord.architectureQuestionMarker, complexity: "high", outcome: "verified",
            createdAt: "t0"))
        try store.insertComponents([ComponentRecord(
            id: "\(runId)-comp", repositoryId: repoId, commitHash: commit, runId: runId,
            investigationId: "\(runId)-inv", name: "App", description: "d", architecturalRole: "core",
            confidence: 0.9, confidenceTier: "high", status: "active", epistemicType: "INTERPRETATION",
            provenance: "claude_code")])
        try store.insertComponentMembers([ComponentMemberRecord(
            id: "\(runId)-m", componentId: "\(runId)-comp", symbolId: "\(runId)-s", confidence: 0.9, role: "core")])
        try store.insertClaims([ClaimRecord(
            id: "\(runId)-claim", repositoryId: repoId, commitHash: commit, runId: runId,
            investigationId: "\(runId)-inv", subjectRef: nil, predicate: nil, objectRef: nil,
            statement: "helper helps", claimType: "BEHAVIOR", confidence: 0.8, status: "active", createdBy: "claude_code")])
        try store.insertEvidence([EvidenceRecord(
            id: "\(runId)-ev", claimId: "\(runId)-claim", fileId: "\(runId)-f", symbolId: "\(runId)-s",
            anchor: "pkg/app.py::helper", startLine: 20, endLine: 22, evidenceType: "source")])
        for (n, label) in concepts.enumerated() {
            let conceptId = DeterministicID.teachingConcept(repositoryId: repoId, kind: "component", subjectLabel: label)
            try store.insertTeachingConcepts([TeachingConceptRecord(
                id: conceptId, repositoryId: repoId, kind: "component", subjectLabel: label, createdAt: "t0")])
            try store.insertTeachingQuestion(TeachingQuestionRecord(
                id: "q-\(repoId)-\(n)", conceptId: conceptId, difficultyBand: 1, explain: "e", prompt: "about \(label)?",
                referenceAnswer: "r", generatedBy: "claude_code", verified: true, createdAt: "t0"))
            try store.insertTeachingRubricCriteria([TeachingRubricCriterionRecord(
                id: "cr-\(repoId)-\(n)", questionId: "q-\(repoId)-\(n)", ordinal: 0, kind: "required", text: "says X")])
        }
        if macRevision {
            try store.insertModelRevision(ModelRevisionRecord(
                id: "rev-mac", repositoryId: repoId, changeSummary: "Mac change", triggeringInvestigationId: "\(runId)-inv",
                createdAt: "t0", revisionNumber: 1))
        }
        try db.dbQueue.close()
        var builder = KnowledgeSnapshotBuilder(databasePath: dbURL, repoRoot: repo)
        builder.now = { "t0" }
        return try builder.build(to: dir.url.appendingPathComponent("out-\(name)"))
    }

    private func concept(_ repoId: String, _ label: String) -> String {
        DeterministicID.teachingConcept(repositoryId: repoId, kind: "component", subjectLabel: label)
    }

    private func openLibrary(_ key: String) throws -> Store {
        Store(try OrionDatabase(path: library.databaseURL(for: key).path, mode: .importedSnapshot))
    }

    private func count(_ store: Store, _ table: String, where condition: String = "1") throws -> Int {
        try store.db.dbQueue.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM \(table) WHERE \(condition)") ?? -1 }
    }

    /// What the device does between syncs: answers a shipped question and one it drafted itself,
    /// builds mastery (and a misconception), and asks -- in a session scoped to a component, and
    /// once without a session -- with the answer triggering a model revision.
    private func learnAndAskOnDevice(_ store: Store, repoId: String, runId: String, commit: String) throws {
        let k1 = concept(repoId, "App")
        let k2 = concept(repoId, "Gone")
        try store.insertTeachingAttempt(TeachingAttemptRecord(
            id: "a-shipped", questionId: "q-\(repoId)-0", answerText: "mine", score: 0.5, verdictTier: "partial", createdAt: "t1"))
        try store.insertTeachingCriterionResults([TeachingCriterionResultRecord(
            id: "res-1", attemptId: "a-shipped", criterionId: "cr-\(repoId)-0", met: false, confidence: "high")])
        try store.insertTeachingAttempt(TeachingAttemptRecord(
            id: "a-gone", questionId: "q-\(repoId)-1", answerText: "mine", score: 1, verdictTier: "solid", createdAt: "t1"))
        try store.insertTeachingQuestion(TeachingQuestionRecord(
            id: "q-device", conceptId: k1, difficultyBand: 1, explain: "e", prompt: "drafted here",
            referenceAnswer: "r", generatedBy: TeachingQuestionSource.device.rawValue, verified: true, createdAt: "t1"))
        try store.insertTeachingRubricCriteria([TeachingRubricCriterionRecord(
            id: "cr-device", questionId: "q-device", ordinal: 0, kind: "required", text: "says Y")])
        try store.insertTeachingAttempt(TeachingAttemptRecord(
            id: "a-device", questionId: "q-device", answerText: "mine", score: 0, verdictTier: "off-track", createdAt: "t2"))
        try store.insertKnowledgeState(KnowledgeStateRecord(
            id: "ks-app", conceptId: k1, pMastered: 0.4, attemptsCount: 2, firstSeenAt: "t1", lastAssessedAt: "t2"))
        try store.insertKnowledgeState(KnowledgeStateRecord(
            id: "ks-gone", conceptId: k2, pMastered: 0.9, attemptsCount: 1, firstSeenAt: "t1", lastAssessedAt: "t1"))
        try store.insertTeachingMisconception(TeachingMisconceptionRecord(
            id: "mis-1", knowledgeStateId: "ks-app", criterionId: "cr-\(repoId)-0", attemptId: "a-shipped",
            statement: "thinks X", detectedAt: "t1"))

        let session = try store.createAskSession(
            repositoryId: repoId, commitHash: commit, scopeType: .component, componentId: "\(runId)-comp",
            title: "about App", now: "t1")
        for inv in ["inv-phone", "inv-solo"] {
            try store.insertInvestigation(InvestigationRecord(
                id: inv, repositoryId: repoId, commitHash: commit, runId: runId, question: "what does helper do?",
                complexity: "low", outcome: "verified", createdAt: "t1", answerText: "it helps"))
            try store.insertRoutingDecision(RoutingDecisionRecord(
                id: "rd-\(inv)", investigationId: inv, depthLevel: 2, method: "heuristic", confidence: "high",
                rationale: "r", createdAt: "t1"))
        }
        _ = try store.recordSessionTurn(sessionId: session.id, investigationId: "inv-phone", claudeSessionId: nil, now: "t1")
        try store.insertAgentToolCall(AgentToolCallRecord(
            id: "tc-1", investigationId: "inv-phone", turnIndex: 1, toolName: "lookup_symbol", arguments: "{}",
            resultSummary: "found", createdAt: "t1"))
        try store.insertClaims([ClaimRecord(
            id: "claim-phone", repositoryId: repoId, commitHash: commit, runId: runId, investigationId: "inv-phone",
            subjectRef: nil, predicate: nil, objectRef: nil, statement: "helper helps a lot", claimType: "BEHAVIOR",
            confidence: 0.7, status: "active", createdBy: "system_local")])
        try store.insertEvidence([EvidenceRecord(
            id: "ev-phone", claimId: "claim-phone", fileId: "\(runId)-f", symbolId: "\(runId)-s",
            anchor: "pkg/app.py::helper", startLine: 20, endLine: 22, evidenceType: "source")])
        try store.insertModelRevision(ModelRevisionRecord(
            id: "rev-phone", repositoryId: repoId, changeSummary: "phone change", triggeringInvestigationId: "inv-phone",
            createdAt: "t1", revisionNumber: 1))
        try store.insertModelRevisionEntries([ModelRevisionEntryRecord(
            id: "rev-phone-e", modelRevisionId: "rev-phone", entityType: "claim", changeType: "added",
            subjectLabel: "helper", previousStateJson: nil, newStateJson: nil, reason: "asked", confidenceTier: nil,
            relatedClaimId: "claim-phone", createdAt: "t1")])
    }

    // MARK: - First import

    func testFirstImportInstallsTheSnapshot() throws {
        let v1 = try macSnapshot(name: "v1", repoId: "r1", commit: "c1", runId: "run1", concepts: ["App"])
        let report = try importer.importSnapshot(at: v1.snapshotURL, expected: v1.manifest)

        XCTAssertFalse(report.replacedExisting)
        XCTAssertEqual(report.migratedFromSchema, "v7_ios_snapshot")
        XCTAssertEqual(report.carried, [:])
        XCTAssertEqual(report.manifest, v1.manifest)
        let entries = try library.entries()
        XCTAssertEqual(entries.map(\.libraryKey), [v1.manifest.libraryKey])
        XCTAssertEqual(entries.first?.manifest.sha256, v1.manifest.sha256)

        let store = try openLibrary(v1.manifest.libraryKey)
        XCTAssertEqual(try store.latestRun(commitHash: nil)?.id, "run1")
        // The phone's evidence lookup: the same slice the Mac shows, from the snippet.
        let slice = try XCTUnwrap(store.evidenceSlice(anchor: "pkg/app.py::helper", startLine: 20, endLine: 22))
        XCTAssertEqual(slice.firstLine, 17)
        XCTAssertEqual(slice.lines.first, "line 17")
        XCTAssertEqual(slice.highlight, 20...22)
        XCTAssertNil(try store.evidenceSlice(anchor: "pkg/app.py::helper", startLine: 1, endLine: 2))
        XCTAssertNil(try store.evidenceSlice(anchor: "pkg/app.py", startLine: nil, endLine: nil))
        // A single self-contained file: no WAL left beside it.
        XCTAssertFalse(FileManager.default.fileExists(atPath: library.databaseURL(for: v1.manifest.libraryKey).path + "-wal")
            && (try? Data(contentsOf: URL(fileURLWithPath: library.databaseURL(for: v1.manifest.libraryKey).path + "-wal")).count) ?? 0 > 0)
    }

    // MARK: - Re-import with carry-over

    /// The Mac re-analyzes at a new commit (new repository id, new run, new file/symbol/component
    /// ids) and drops the "Gone" concept. Everything the device did must survive, re-homed.
    func testReimportCarriesTheDevicesLearningAndAsking() throws {
        let v1 = try macSnapshot(name: "v1", repoId: "r1", commit: "c1", runId: "run1", concepts: ["App", "Gone"])
        try importer.importSnapshot(at: v1.snapshotURL, expected: v1.manifest)
        let key = v1.manifest.libraryKey
        do {
            let device = try openLibrary(key)
            try learnAndAskOnDevice(device, repoId: "r1", runId: "run1", commit: "c1")
            try device.db.dbQueue.close()
        }

        let v2 = try macSnapshot(name: "v2", repoId: "r2", commit: "c2", runId: "run2", concepts: ["App"], macRevision: true)
        XCTAssertEqual(v2.manifest.libraryKey, key, "same checkout, same library slot")
        let report = try importer.importSnapshot(at: v2.snapshotURL, expected: v2.manifest)

        XCTAssertTrue(report.replacedExisting)
        XCTAssertEqual(report.orphaned, [:])
        XCTAssertEqual(report.staleConceptsKept, 1)
        XCTAssertEqual(report.carried, [
            "teaching_questions": 3, "teaching_rubric_criteria": 3, "teaching_attempts": 3,
            "teaching_criterion_results": 1, "knowledge_states": 2, "teaching_misconceptions": 1,
            "investigations": 2, "claims": 1, "evidence": 1, "routing_decisions": 2, "agent_tool_calls": 1,
            "ask_sessions": 1, "ask_session_turns": 1, "model_revisions": 1, "model_revision_entries": 1,
        ])

        let store = try openLibrary(key)
        // The new Mac knowledge is there.
        XCTAssertEqual(try store.latestRun(commitHash: nil)?.id, "run2")
        XCTAssertEqual(try count(store, "teaching_questions", where: "id = 'q-r2-0'"), 1)

        // Mastery follows the concept by name onto the new concept id.
        let states = Dictionary(uniqueKeysWithValues: try store.knowledgeStates().map { ($0.id, $0) })
        XCTAssertEqual(states["ks-app"]?.conceptId, concept("r2", "App"))
        XCTAssertEqual(states["ks-app"]?.pMastered, 0.4)
        // The dropped concept is kept -- stale, on the new repository -- because the device learned it.
        XCTAssertEqual(states["ks-gone"]?.conceptId, concept("r1", "Gone"))
        XCTAssertEqual(try count(store, "teaching_concepts", where: "id = '\(concept("r1", "Gone"))' AND stale = 1 AND repository_id = 'r2'"), 1)

        // Questions the Mac no longer ships but the device answered, and the device's own draft,
        // come across on the new concepts with their attempts.
        XCTAssertEqual(try count(store, "teaching_questions", where: "id = 'q-r1-0' AND concept_id = '\(concept("r2", "App"))'"), 1)
        XCTAssertEqual(try count(store, "teaching_questions", where: "id = 'q-device' AND generated_by = 'device'"), 1)
        XCTAssertEqual(try count(store, "teaching_attempts"), 3)
        XCTAssertEqual(try count(store, "teaching_misconceptions", where: "cleared_at IS NULL"), 1)

        // Asks are re-homed onto the new analysis; links into the old one are cleared, not dropped.
        let session = try XCTUnwrap(store.askSessions(repositoryId: "r2", commitHash: "c2").first)
        XCTAssertEqual(session.scopeType, AskSessionScope.repository.rawValue, "its component no longer exists")
        XCTAssertNil(session.componentId)
        XCTAssertEqual(try count(store, "investigations", where: "id IN ('inv-phone', 'inv-solo') AND run_id = 'run2' AND repository_id = 'r2'"), 2)
        XCTAssertEqual(try count(store, "claims", where: "id = 'claim-phone' AND run_id = 'run2'"), 1)
        XCTAssertEqual(try count(store, "evidence", where: "id = 'ev-phone' AND file_id IS NULL AND symbol_id IS NULL"), 1)

        // The device's revision now follows the Mac's newest one.
        let revision = try XCTUnwrap(try store.db.dbQueue.read {
            try Row.fetchOne($0, sql: "SELECT previous_revision, revision_number FROM model_revisions WHERE id = 'rev-phone'")
        })
        XCTAssertEqual(revision["previous_revision"] as String?, "rev-mac")
        XCTAssertEqual(revision["revision_number"] as Int?, 2)
    }

    func testASecondReimportKeepsEverythingAgain() throws {
        let v1 = try macSnapshot(name: "v1", repoId: "r1", commit: "c1", runId: "run1", concepts: ["App", "Gone"])
        try importer.importSnapshot(at: v1.snapshotURL)
        let key = v1.manifest.libraryKey
        do {
            let device = try openLibrary(key)
            try learnAndAskOnDevice(device, repoId: "r1", runId: "run1", commit: "c1")
            try device.db.dbQueue.close()
        }
        let v2 = try macSnapshot(name: "v2", repoId: "r2", commit: "c2", runId: "run2", concepts: ["App"])
        let first = try importer.importSnapshot(at: v2.snapshotURL)
        let second = try importer.importSnapshot(at: v2.snapshotURL)
        XCTAssertEqual(second.carried, first.carried)
        XCTAssertEqual(second.orphaned, [:])
        XCTAssertEqual(second.staleConceptsKept, 1)
    }

    // MARK: - Refusals

    func testDamagedTransferIsRefusedAndLeavesTheLibraryAlone() throws {
        let v1 = try macSnapshot(name: "v1", repoId: "r1", commit: "c1", runId: "run1", concepts: ["App"])
        try importer.importSnapshot(at: v1.snapshotURL)
        let key = v1.manifest.libraryKey
        do {
            let device = try openLibrary(key)
            try device.insertTeachingAttempt(TeachingAttemptRecord(
                id: "a1", questionId: "q-r1-0", answerText: "x", score: 1, verdictTier: "solid", createdAt: "t1"))
            try device.db.dbQueue.close()
        }

        var wrong = v1.manifest
        wrong.sha256 = String(repeating: "0", count: 64)
        XCTAssertThrowsError(try importer.importSnapshot(at: v1.snapshotURL, expected: wrong)) { error in
            guard case .checksumMismatch = error as? KnowledgeSnapshotImporter.ImportError else {
                return XCTFail("\(error)")
            }
        }
        let garbage = dir.url.appendingPathComponent("garbage.orionsnap")
        try Data("not a snapshot".utf8).write(to: garbage)
        XCTAssertThrowsError(try importer.importSnapshot(at: garbage)) { error in
            guard case .notASnapshot = error as? KnowledgeSnapshotImporter.ImportError else { return XCTFail("\(error)") }
        }

        XCTAssertEqual(try count(try openLibrary(key), "teaching_attempts"), 1)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: library.root.path).filter { $0.hasPrefix(".incoming") }, [])
    }

    func testSnapshotFromANewerOrionIsRefused() throws {
        let v1 = try macSnapshot(name: "v1", repoId: "r1", commit: "c1", runId: "run1", concepts: ["App"])
        let newerSchema = try rewrite(v1.snapshotURL) { try $0.execute(sql: "INSERT INTO grdb_migrations VALUES ('v99_future')") }
        XCTAssertThrowsError(try importer.importSnapshot(at: newerSchema)) { error in
            guard case .newerSchema = error as? OrionDatabase.OpenError else { return XCTFail("\(error)") }
        }
        let newerFormat = try rewrite(v1.snapshotURL) {
            try $0.execute(sql: "UPDATE snapshot_manifest SET json = json_set(json, '$.formatVersion', 99)")
        }
        XCTAssertThrowsError(try importer.importSnapshot(at: newerFormat)) { error in
            XCTAssertEqual(error as? KnowledgeSnapshotImporter.ImportError, .unsupportedFormat(99))
        }
        XCTAssertEqual(try library.entries(), [])
    }

    func testSnapshotForAnotherRepositoryIsRefused() throws {
        let v1 = try macSnapshot(name: "v1", repoId: "r1", commit: "c1", runId: "run1", concepts: ["App"])
        var other = v1.manifest
        other.libraryKey = "someone-else"
        XCTAssertThrowsError(try importer.importSnapshot(at: v1.snapshotURL, expected: other)) { error in
            XCTAssertEqual(
                error as? KnowledgeSnapshotImporter.ImportError,
                .libraryKeyMismatch(expected: "someone-else", actual: v1.manifest.libraryKey))
        }
    }

    func testRemoveDeletesTheRepositoryFromTheDevice() throws {
        let v1 = try macSnapshot(name: "v1", repoId: "r1", commit: "c1", runId: "run1", concepts: ["App"])
        try importer.importSnapshot(at: v1.snapshotURL)
        try library.remove(libraryKey: v1.manifest.libraryKey)
        XCTAssertEqual(try library.entries(), [])
    }

    /// Decompresses a snapshot, edits its database, and writes it back compressed.
    private func rewrite(_ url: URL, _ edit: (Database) throws -> Void) throws -> URL {
        let raw = dir.url.appendingPathComponent("edit-\(UUID().uuidString).db")
        try KnowledgeSnapshotFormat.decompress(try Data(contentsOf: url)).write(to: raw)
        let queue = try DatabaseQueue(path: raw.path)
        try queue.write(edit)
        try queue.close()
        let out = dir.url.appendingPathComponent("edited-\(UUID().uuidString).orionsnap")
        try KnowledgeSnapshotFormat.compress(try Data(contentsOf: raw)).write(to: out)
        return out
    }
}
