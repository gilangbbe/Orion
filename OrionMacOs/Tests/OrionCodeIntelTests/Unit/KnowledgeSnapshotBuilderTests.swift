import GRDB
import XCTest

@testable import OrionCodeIntel
@testable import OrionCore

/// Docs/19 M2: `KnowledgeSnapshotBuilder` against a hand-built repository and database -- the
/// same fixture style as `ConceptExtractorTests`, plus a real checkout on disk for the snippets.
final class KnowledgeSnapshotBuilderTests: XCTestCase {
    private var dir: TempDir!
    private var repo: URL { dir.url.appendingPathComponent("demo", isDirectory: true) }
    private var dbPath: URL { repo.appendingPathComponent(".orion/orion.db") }
    private var outDir: URL { dir.url.appendingPathComponent("out", isDirectory: true) }
    /// `pkg/app.py` is "line 1" ... "line 30".
    private let appLines = (1...30).map { "line \($0)" }

    override func setUpWithError() throws {
        dir = try TempDir("orion-snapshot-test")
        try dir.write("demo/pkg/app.py", appLines.joined(separator: "\n"))
        try dir.write("demo/pkg/stale.py", "edited after the analysis\n")
        try seed()
    }

    override func tearDown() { dir = nil }

    // MARK: - Fixture

    private func seed() throws {
        let db = try OrionDatabase(path: dbPath.path)
        let store = Store(db)
        let appSha = KnowledgeSnapshotFormat.sha256Hex(Data(appLines.joined(separator: "\n").utf8))
        try db.dbQueue.write { dbc in
            // An older repository row (an earlier commit) and the current one, same checkout.
            for (id, commit) in [("old", "c-old"), ("cur", "unversioned")] {
                try RepositoryRecord(
                    id: id, sourceURL: nil, localPath: repo.path, commitHash: commit, languages: ["python"],
                    analysisStatus: .succeeded, createdAt: "t0", updatedAt: "t0"
                ).insert(dbc)
            }
            // The newest run failed: the Mac app shows the latest *succeeded* one, run-cur.
            for (id, repoId, commit, status, started) in [
                ("run-old", "old", "c-old", "succeeded", "2026-01-01T00:00:00Z"),
                ("run-cur", "cur", "unversioned", "succeeded", "2026-02-01T00:00:00Z"),
                ("run-failed", "cur", "unversioned", "failed", "2026-03-01T00:00:00Z"),
            ] {
                try AnalysisRunRecord(
                    id: id, repositoryId: repoId, commitHash: commit, status: status, startedAt: started,
                    orionVersion: "0.1.0", resolver: "none", grammarVersions: [:], toolVersions: [:],
                    stageTimings: [:], fileCount: 0, symbolCount: 0, relationshipCount: 0, diagnosticCount: 0
                ).insert(dbc)
            }
            for (id, runId, repoId, commit, path, sha) in [
                ("f-app", "run-cur", "cur", "unversioned", "pkg/app.py", appSha),
                ("f-stale", "run-cur", "cur", "unversioned", "pkg/stale.py", "sha-at-analysis-time"),
                ("f-old", "run-old", "old", "c-old", "pkg/app.py", appSha),
            ] {
                try FileRecord(
                    id: id, repositoryId: repoId, commitHash: commit, runId: runId, path: path, language: "python",
                    sha256: sha, byteSize: 0, lineCount: 0, isTest: false, isPackageInit: false, parseOk: true
                ).insert(dbc)
            }
            for (id, fileId, anchor, start, end) in [
                ("s-class", "f-app", "pkg/app.py::App", 5, 12),
                ("s-helper", "f-app", "pkg/app.py::helper", 20, 22),
                ("s-module", "f-app", "pkg/app.py::Big", 1, 30),
                ("s-stale", "f-stale", "pkg/stale.py::Old", 1, 2),
            ] {
                try SymbolRecord(
                    id: id, repositoryId: "cur", commitHash: "unversioned", runId: "run-cur", fileId: fileId,
                    name: id, qualifiedName: anchor, anchor: anchor, kind: "class", startLine: start, startCol: 0,
                    endLine: end, endCol: 0, startByte: 0, endByte: 0, decorators: [], visibility: "public",
                    isExported: true, epistemicType: "FACT"
                ).insert(dbc)
            }
            try DiagnosticRecord(
                id: "d1", repositoryId: "cur", commitHash: "unversioned", runId: "run-cur", stage: "parse",
                severity: "warning", code: "X", message: "at /Users/someone/demo/pkg/app.py"
            ).insert(dbc)
        }

        try store.insertInvestigation(InvestigationRecord(
            id: "inv-cur", repositoryId: "cur", commitHash: "unversioned", runId: "run-cur",
            question: InvestigationRecord.architectureQuestionMarker, complexity: "high", outcome: "verified",
            createdAt: "t1"))
        try store.insertInvestigation(InvestigationRecord(
            id: "inv-old", repositoryId: "old", commitHash: "c-old", runId: "run-old",
            question: InvestigationRecord.architectureQuestionMarker, complexity: "high", outcome: "verified",
            createdAt: "t0"))
        try store.insertComponents([ComponentRecord(
            id: "comp", repositoryId: "cur", commitHash: "unversioned", runId: "run-cur", investigationId: "inv-cur",
            name: "App", description: "the app", architecturalRole: "core", confidence: 0.9, confidenceTier: "high",
            status: "active", epistemicType: "INTERPRETATION", provenance: "claude_code")])
        try store.insertComponentMembers([ComponentMemberRecord(
            id: "m1", componentId: "comp", symbolId: "s-class", confidence: 0.9, role: "core")])
        try store.insertClaims([ClaimRecord(
            id: "cl1", repositoryId: "cur", commitHash: "unversioned", runId: "run-cur", investigationId: "inv-cur",
            subjectRef: nil, predicate: nil, objectRef: nil, statement: "helper does X", claimType: "BEHAVIOR",
            confidence: 0.8, status: "active", createdBy: "claude_code")])
        try store.insertEvidence([
            EvidenceRecord(id: "e1", claimId: "cl1", fileId: "f-app", symbolId: "s-helper",
                           anchor: "pkg/app.py::helper", startLine: 20, endLine: 22, evidenceType: "source"),
            EvidenceRecord(id: "e2", claimId: "cl1", fileId: "f-stale", symbolId: "s-stale",
                           anchor: "pkg/stale.py::Old", startLine: 1, endLine: 2, evidenceType: "source"),
        ])

        try store.insertTeachingConcepts([
            TeachingConceptRecord(id: "k1", repositoryId: "cur", kind: "component", subjectLabel: "App", createdAt: "t1"),
            TeachingConceptRecord(id: "k-old", repositoryId: "old", kind: "component", subjectLabel: "Old", createdAt: "t0"),
        ])
        try store.insertTeachingQuestion(TeachingQuestionRecord(
            id: "q-ok", conceptId: "k1", difficultyBand: 1, explain: "e", prompt: "p", referenceAnswer: "r",
            referenceAnchors: ["pkg/app.py::Big"], generatedBy: "claude", verified: true, createdAt: "t1"))
        try store.insertTeachingRubricCriteria([TeachingRubricCriterionRecord(
            id: "cr1", questionId: "q-ok", ordinal: 0, kind: "required", text: "mentions helper",
            evidenceAnchors: ["pkg/app.py::helper", "pkg/missing.py::Nope"])])
        try store.insertTeachingQuestion(TeachingQuestionRecord(
            id: "q-draft", conceptId: "k1", difficultyBand: 1, explain: "e", prompt: "p", referenceAnswer: "r",
            generatedBy: "local", verified: false, createdAt: "t1"))

        // The Mac's own learning and asking, and its traces -- none of it may reach the phone.
        try store.insertTeachingAttempt(TeachingAttemptRecord(
            id: "a1", questionId: "q-ok", answerText: "mine", score: 0.5, verdictTier: "partial", createdAt: "t2"))
        try store.insertKnowledgeState(KnowledgeStateRecord(
            id: "ks1", conceptId: "k1", firstSeenAt: "t2", lastAssessedAt: "t2"))
        _ = try store.createAskSession(
            repositoryId: "cur", commitHash: "unversioned", scopeType: .repository, title: "q", now: "t2")
        try store.insertRoutingDecision(RoutingDecisionRecord(
            id: "rd1", investigationId: "inv-cur", depthLevel: 2, method: "heuristic", confidence: "high",
            rationale: "r", createdAt: "t2"))
    }

    private func build(commit: String? = nil) throws -> (KnowledgeSnapshotBuilder.Output, Store) {
        var builder = KnowledgeSnapshotBuilder(databasePath: dbPath, repoRoot: repo, commit: commit)
        builder.maxSnippetLines = 20
        builder.now = { "2026-09-30T00:00:00Z" }
        let output = try builder.build(to: outDir)

        let restored = dir.url.appendingPathComponent("restored-\(UUID().uuidString).db")
        try KnowledgeSnapshotFormat.decompress(try Data(contentsOf: output.snapshotURL)).write(to: restored)
        return (output, Store(try OrionDatabase(path: restored.path, mode: .importedSnapshot)))
    }

    private func count(_ store: Store, _ table: String) throws -> Int {
        try store.db.dbQueue.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM \(table)") ?? -1 }
    }

    // MARK: - Tests

    func testKeepsOnlyTheRunTheMacShows() throws {
        let (output, store) = try build()
        XCTAssertEqual(output.manifest.runId, "run-cur")
        XCTAssertEqual(try store.db.dbQueue.read { try String.fetchAll($0, sql: "SELECT id FROM analysis_runs") }, ["run-cur"])
        XCTAssertEqual(try count(store, "repositories"), 1)
        XCTAssertEqual(try store.db.dbQueue.read { try String.fetchAll($0, sql: "SELECT id FROM teaching_concepts") }, ["k1"])
        XCTAssertEqual(try store.db.dbQueue.read { try String.fetchAll($0, sql: "SELECT id FROM investigations") }, ["inv-cur"])
        XCTAssertEqual(try count(store, "components"), 1)
        XCTAssertEqual(try count(store, "evidence"), 2)
    }

    func testDropsLearningAsksTracesAndUnverifiedQuestions() throws {
        let (_, store) = try build()
        for table in [
            "teaching_attempts", "teaching_criterion_results", "knowledge_states", "teaching_misconceptions",
            "ask_sessions", "ask_session_turns", "routing_decisions", "agent_tool_calls", "diagnostics",
        ] {
            XCTAssertEqual(try count(store, table), 0, table)
        }
        XCTAssertEqual(try store.db.dbQueue.read { try String.fetchAll($0, sql: "SELECT id FROM teaching_questions") }, ["q-ok"])
        XCTAssertEqual(try count(store, "teaching_rubric_criteria"), 1)
    }

    func testNoMacPathLeavesTheMachine() throws {
        let (_, store) = try build()
        XCTAssertEqual(
            try store.db.dbQueue.read { try String.fetchAll($0, sql: "SELECT local_path FROM repositories") }, ["demo"])
    }

    func testSnippetsCoverEveryCitedRangeAndMatchTheCheckout() throws {
        let (output, store) = try build()
        // Claim evidence 20-22 (also a criterion anchor, stored once): lines 17-25 with context.
        let helper = try XCTUnwrap(store.evidenceSnippet(filePath: "pkg/app.py", startLine: 20, endLine: 22))
        XCTAssertEqual(helper.firstLine, 17)
        XCTAssertEqual(helper.text, appLines[16...24].joined(separator: "\n"))
        XCTAssertFalse(helper.truncated)
        // Component member 5-12: lines 2-15.
        let member = try XCTUnwrap(store.evidenceSnippet(filePath: "pkg/app.py", startLine: 5, endLine: 12))
        XCTAssertEqual(member.firstLine, 2)
        XCTAssertEqual(member.text.components(separatedBy: "\n").count, 14)
        // Question reference anchor 1-30: capped at 20 lines.
        let module = try XCTUnwrap(store.evidenceSnippet(filePath: "pkg/app.py", startLine: 1, endLine: 30))
        XCTAssertTrue(module.truncated)
        XCTAssertEqual(module.text, appLines[0..<20].joined(separator: "\n"))
        // The file changed since the analysis: no snippet, counted as skipped. The unresolvable
        // criterion anchor never becomes a range at all.
        XCTAssertNil(try store.evidenceSnippet(filePath: "pkg/stale.py", startLine: 1, endLine: 2))
        XCTAssertEqual(try store.evidenceSnippetCount(), 3)
        XCTAssertEqual(output.manifest.counts.snippets, 3)
        XCTAssertEqual(output.manifest.counts.snippetsSkipped, 1)
    }

    func testManifestDescribesTheFile() throws {
        let (output, store) = try build()
        let file = try Data(contentsOf: output.snapshotURL)
        let manifest = output.manifest
        XCTAssertEqual(manifest.sha256, KnowledgeSnapshotFormat.sha256Hex(file))
        XCTAssertEqual(manifest.snapshotByteCount, file.count)
        XCTAssertEqual(manifest.databaseByteCount, try KnowledgeSnapshotFormat.decompress(file).count)
        XCTAssertEqual(manifest.schemaVersion, "v7_ios_snapshot")
        XCTAssertEqual(manifest.libraryKey, KnowledgeSnapshotFormat.libraryKey(sourceURL: nil, localPath: repo.path))
        XCTAssertEqual(manifest.repositoryName, "demo")
        XCTAssertEqual(manifest.counts.components, 1)
        XCTAssertEqual(manifest.counts.teachingQuestions, 1)
        XCTAssertEqual(output.snapshotURL.lastPathComponent, "demo-unversioned.orionsnap")
        XCTAssertEqual(try KnowledgeSnapshotManifest.decode(Data(contentsOf: output.manifestURL)), manifest)

        // The copy inside the file is the same, minus what only the finished file can know.
        var embedded = manifest
        embedded.databaseByteCount = nil
        embedded.snapshotByteCount = nil
        embedded.sha256 = nil
        XCTAssertEqual(try store.snapshotManifest(), embedded)
    }

    func testIsSelfContainedAndConsistent() throws {
        let (output, _) = try build()
        let raw = dir.url.appendingPathComponent("raw.db")
        try KnowledgeSnapshotFormat.decompress(try Data(contentsOf: output.snapshotURL)).write(to: raw)
        let queue = try DatabaseQueue(path: raw.path)
        try queue.read { dbc in
            XCTAssertEqual(try String.fetchOne(dbc, sql: "PRAGMA journal_mode"), "delete")
            XCTAssertEqual(try String.fetchAll(dbc, sql: "PRAGMA integrity_check"), ["ok"])
            XCTAssertTrue(try Row.fetchAll(dbc, sql: "PRAGMA foreign_key_check").isEmpty)
        }
    }

    func testLeavesTheMacDatabaseAlone() throws {
        _ = try build()
        let store = Store(try OrionDatabase(path: dbPath.path))
        XCTAssertEqual(try count(store, "repositories"), 2)
        XCTAssertEqual(try count(store, "teaching_attempts"), 1)
        XCTAssertEqual(try count(store, "evidence_snippets"), 0)
    }

    func testCommitPicksThatCommitsRun() throws {
        let (output, store) = try build(commit: "c-old")
        XCTAssertEqual(output.manifest.runId, "run-old")
        XCTAssertEqual(output.manifest.commitHash, "c-old")
        XCTAssertEqual(try store.db.dbQueue.read { try String.fetchAll($0, sql: "SELECT id FROM teaching_concepts") }, ["k-old"])
        // Same checkout, so the same library slot on the phone.
        XCTAssertEqual(
            output.manifest.libraryKey, KnowledgeSnapshotFormat.libraryKey(sourceURL: nil, localPath: repo.path))
    }

    func testNoSucceededRunIsAnError() throws {
        XCTAssertThrowsError(try KnowledgeSnapshotBuilder(databasePath: dbPath, repoRoot: repo, commit: "nope")
            .build(to: outDir)) { error in
            XCTAssertEqual(
                error as? KnowledgeSnapshotBuilder.BuildError,
                .noSucceededRun(databasePath: dbPath.path, commit: "nope"))
        }
    }
}

/// Docs/19 M2: the portable format pieces the phone's importer (M3) will rely on.
final class KnowledgeSnapshotFormatTests: XCTestCase {
    func testCompressionRoundTrips() throws {
        let data = Data((0..<10_000).map { UInt8($0 % 7) })
        let compressed = try KnowledgeSnapshotFormat.compress(data)
        XCTAssertLessThan(compressed.count, data.count)
        XCTAssertEqual(try KnowledgeSnapshotFormat.decompress(compressed), data)
    }

    func testLibraryKeyPrefersTheSourceURLAndIsStable() {
        let viaURL = KnowledgeSnapshotFormat.libraryKey(sourceURL: "https://github.com/o/r", localPath: "/a")
        XCTAssertEqual(viaURL, KnowledgeSnapshotFormat.libraryKey(sourceURL: "https://github.com/o/r", localPath: "/b"))
        XCTAssertNotEqual(viaURL, KnowledgeSnapshotFormat.libraryKey(sourceURL: nil, localPath: "/a"))
        XCTAssertEqual(
            KnowledgeSnapshotFormat.libraryKey(sourceURL: "", localPath: "/a"),
            KnowledgeSnapshotFormat.libraryKey(sourceURL: nil, localPath: "/a"))
        XCTAssertEqual(viaURL.count, 24)
    }
}

/// Docs/19 M2: the one slicing rule the Mac's evidence view and the snapshot share.
final class EvidenceSliceTests: XCTestCase {
    private let lines = (1...10).map { "l\($0)" }

    func testRangePlusContextClampedToTheFile() throws {
        let slice = try EvidenceSlice.slice(lines: lines, start: 2, end: 3)
        XCTAssertEqual(slice.firstLine, 1)
        XCTAssertEqual(slice.lines, Array(lines[0...5]))
        XCTAssertEqual(slice.highlight, 2...3)
        XCTAssertFalse(slice.truncated)
        XCTAssertEqual(try EvidenceSlice.slice(lines: lines, start: 9, end: 10).lines, Array(lines[5...9]))
    }

    func testCapTruncates() throws {
        let slice = try EvidenceSlice.slice(lines: lines, start: 1, end: 10, maxLines: 4)
        XCTAssertEqual(slice.lines, Array(lines[0...3]))
        XCTAssertTrue(slice.truncated)
    }

    func testNoRangeShowsTheHead() throws {
        let slice = try EvidenceSlice.slice(lines: lines, start: nil, end: nil, maxLinesWithNoRange: 3)
        XCTAssertEqual(slice.lines, Array(lines[0...2]))
        XCTAssertNil(slice.highlight)
        XCTAssertTrue(slice.truncated)
    }

    func testRangePastTheEndIsInvalid() {
        XCTAssertThrowsError(try EvidenceSlice.slice(lines: lines, start: 11, end: 12))
    }

    func testFilePathForAnchor() {
        XCTAssertEqual(EvidenceSlice.filePath(forAnchor: "a/b.py::C.d"), "a/b.py")
        XCTAssertEqual(EvidenceSlice.filePath(forAnchor: "a/b.py"), "a/b.py")
    }
}
