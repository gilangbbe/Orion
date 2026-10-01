import Foundation
import GRDB
import OrionCore

/// A minimal knowledge snapshot assembled with `OrionCore` alone -- the Mac's
/// `KnowledgeSnapshotBuilder` lives in `OrionCodeIntel`, which doesn't build for iOS. Same shape:
/// one repository and run, an architecture investigation with one component, a claim with
/// evidence, its snippet, and the embedded manifest.
enum SnapshotFixture {
    static let anchor = "pkg/app.py::helper"

    /// Writes `<directory>/<name>.orionsnap` (+ `.manifest.json` when `withManifest`) and
    /// returns the snapshot's manifest (with size and sha256).
    @discardableResult
    static func write(
        to directory: URL, name: String = "demo", repositoryName: String = "demo", withManifest: Bool = true
    ) throws -> KnowledgeSnapshotManifest {
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("fixture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let dbURL = work.appendingPathComponent("snapshot.db")
        let db = try OrionDatabase(path: dbURL.path, mode: .importedSnapshot)
        let store = Store(db)
        try db.dbQueue.write { dbc in
            try RepositoryRecord(
                id: "repo", sourceURL: nil, localPath: repositoryName, commitHash: "c0ffee1234", languages: ["python"],
                analysisStatus: .succeeded, createdAt: "t0", updatedAt: "t0"
            ).insert(dbc)
            try AnalysisRunRecord(
                id: "run", repositoryId: "repo", commitHash: "c0ffee1234", status: "succeeded",
                startedAt: "2026-09-06T12:00:00Z", orionVersion: "0.1.0", resolver: "none", grammarVersions: [:],
                toolVersions: [:], stageTimings: [:], fileCount: 1, symbolCount: 1, relationshipCount: 0,
                diagnosticCount: 0
            ).insert(dbc)
            try FileRecord(
                id: "f", repositoryId: "repo", commitHash: "c0ffee1234", runId: "run", path: "pkg/app.py",
                language: "python", modulePath: "pkg.app", sha256: "sha", byteSize: 0, lineCount: 30, isTest: false,
                isPackageInit: false, parseOk: true
            ).insert(dbc)
            try SymbolRecord(
                id: "s", repositoryId: "repo", commitHash: "c0ffee1234", runId: "run", fileId: "f", name: "helper",
                qualifiedName: "pkg.app.helper", anchor: anchor, kind: "function", startLine: 20, startCol: 0,
                endLine: 22, endCol: 0, startByte: 0, endByte: 0, decorators: [], visibility: "public",
                isExported: true, epistemicType: "FACT"
            ).insert(dbc)
        }
        try store.insertInvestigation(InvestigationRecord(
            id: "inv", repositoryId: "repo", commitHash: "c0ffee1234", runId: "run",
            question: InvestigationRecord.architectureQuestionMarker, complexity: "high", outcome: "verified",
            createdAt: "2026-09-07T00:00:00Z"))
        try store.insertComponents([ComponentRecord(
            id: "comp", repositoryId: "repo", commitHash: "c0ffee1234", runId: "run", investigationId: "inv",
            name: "App Core", description: "Runs the app.", architecturalRole: "core", confidence: 0.9,
            confidenceTier: "high", status: "active", epistemicType: "INTERPRETATION", provenance: "claude_code")])
        try store.insertComponentMembers([ComponentMemberRecord(
            id: "m", componentId: "comp", symbolId: "s", confidence: 0.9, role: "core")])
        try store.insertClaims([ClaimRecord(
            id: "claim", repositoryId: "repo", commitHash: "c0ffee1234", runId: "run", investigationId: "inv",
            subjectRef: anchor, predicate: nil, objectRef: nil, statement: "helper helps", claimType: "BEHAVIOR",
            confidence: 0.8, status: "active", createdBy: "claude_code")])
        try store.insertEvidence([EvidenceRecord(
            id: "ev", claimId: "claim", fileId: "f", symbolId: "s", anchor: anchor, startLine: 20, endLine: 22,
            evidenceType: "source")])
        try store.insertEvidenceSnippets([EvidenceSnippetRecord(
            filePath: "pkg/app.py", startLine: 20, endLine: 22, firstLine: 17,
            text: (17...25).map { "line \($0)" }.joined(separator: "\n"), truncated: false, fileSha256: "sha")])

        var manifest = KnowledgeSnapshotManifest(
            schemaVersion: OrionMigrations.makeMigrator().migrations.last ?? "",
            libraryKey: KnowledgeSnapshotFormat.libraryKey(sourceURL: nil, localPath: "/mac/\(repositoryName)"),
            repositoryName: repositoryName, sourceURL: nil, commitHash: "c0ffee1234", runId: "run",
            analyzedAt: "2026-09-06T12:00:00Z", createdAt: "2026-09-30T00:00:00Z", orionVersion: "0.1.0",
            counts: .init(
                files: 1, symbols: 1, relationships: 0, components: 1, claims: 1, evidence: 1, modelRevisions: 0,
                teachingConcepts: 0, teachingQuestions: 0, snippets: 1, snippetsSkipped: 0))
        try db.dbQueue.write { dbc in
            try dbc.execute(
                sql: "INSERT INTO snapshot_manifest (id, json) VALUES (1, ?)",
                arguments: [String(decoding: try manifest.json(), as: UTF8.self)])
        }
        try db.dbQueue.writeWithoutTransaction { try $0.execute(sql: "PRAGMA journal_mode = DELETE") }
        try db.dbQueue.close()

        let database = try Data(contentsOf: dbURL)
        let compressed = try KnowledgeSnapshotFormat.compress(database)
        try compressed.write(to: directory.appendingPathComponent("\(name).orionsnap"))
        manifest.databaseByteCount = database.count
        manifest.snapshotByteCount = compressed.count
        manifest.sha256 = KnowledgeSnapshotFormat.sha256Hex(compressed)
        if withManifest {
            try manifest.json().write(to: directory.appendingPathComponent("\(name).manifest.json"))
        }
        return manifest
    }
}
