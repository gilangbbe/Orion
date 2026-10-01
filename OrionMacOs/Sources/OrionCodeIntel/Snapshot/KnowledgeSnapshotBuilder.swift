import Foundation
import GRDB

/// Builds a knowledge snapshot (Docs/19 M2): the Codebase Model the Mac app currently shows for a
/// repository, trimmed for the iOS companion, plus the source lines its evidence views cite.
///
/// Lives in `OrionCodeIntel`, not `OrionCore`, because it reads the analyzed checkout.
///
/// What goes in:
/// - **One run.** The run the Mac app shows -- `Store.latestRun(commitHash:)`, succeeded -- and
///   its repository row. Other repository rows and runs are deleted, and everything scoped to them
///   goes by `ON DELETE CASCADE`. That includes model revisions triggered by their
///   investigations, and teaching concepts of other repository rows.
/// - **Knowledge, not learning.** Components, claims, evidence, revisions, teaching concepts and
///   *verified* questions with their criteria stay. The Mac's attempts, criterion results,
///   knowledge states, misconceptions and ask sessions go: the phone keeps its own progress
///   (Docs/19 decision 4).
/// - **No Mac-only traces.** `routing_decisions`, `agent_tool_calls` and `diagnostics` go, and
///   `repositories.local_path` becomes the repository's name, so no Mac path leaves the machine.
/// - **Evidence snippets** (`evidence_snippets`) for every range an evidence view can open: claim
///   evidence, semantic component members, and the anchors of the kept teaching questions and
///   criteria, resolved to their symbols. A file whose bytes no longer match `files.sha256` gets
///   none, so a snippet never shows code the analysis didn't see. Structural (module) members and
///   concept anchors get none; the first would be the whole codebase, and the second are only
///   read as signatures.
public struct KnowledgeSnapshotBuilder {
    public struct Output: Sendable {
        public let manifest: KnowledgeSnapshotManifest
        public let snapshotURL: URL
        public let manifestURL: URL
    }

    public enum BuildError: Error, LocalizedError, Equatable {
        case noSucceededRun(databasePath: String, commit: String?)
        case integrityCheckFailed(String)

        public var errorDescription: String? {
            switch self {
            case .noSucceededRun(let path, let commit):
                return "no succeeded analysis run\(commit.map { " for commit \($0)" } ?? "") in \(path)"
                    + " -- run `orion-index analyze` first"
            case .integrityCheckFailed(let detail):
                return "the trimmed snapshot failed its integrity check: \(detail)"
            }
        }
    }

    public let databasePath: URL
    public let repoRoot: URL
    /// `nil`: the latest succeeded run, what the Mac app shows. A hash picks that commit's run.
    public var commit: String?
    public var maxSnippetLines = EvidenceSlice.snapshotMaxLines
    public var now: () -> String = Timestamp.now

    public init(databasePath: URL, repoRoot: URL, commit: String? = nil) {
        self.databasePath = databasePath
        self.repoRoot = repoRoot
        self.commit = commit
    }

    /// Writes `<name>.orionsnap` and `<name>.manifest.json` into `outputDirectory`.
    /// `name` defaults to `<repository>-<commit prefix>`.
    public func build(to outputDirectory: URL, name: String? = nil) throws -> Output {
        let source = try OrionDatabase(path: databasePath.path)
        let sourceStore = Store(source)
        guard let run = try sourceStore.latestRun(commitHash: commit), run.status == AnalysisStatus.succeeded.rawValue,
              let repository = try sourceStore.repository(id: run.repositoryId)
        else { throw BuildError.noSucceededRun(databasePath: databasePath.path, commit: commit) }

        let repositoryName = repoRoot.standardizedFileURL.lastPathComponent
        let libraryKey = KnowledgeSnapshotFormat.libraryKey(
            sourceURL: repository.sourceURL, localPath: repository.localPath)

        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("orion-snapshot-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDir) }
        let workingPath = workDir.appendingPathComponent("snapshot.db").path

        // A consistent copy, WAL contents included, without touching the Mac's database.
        try source.dbQueue.inDatabase { try $0.execute(sql: "VACUUM INTO ?", arguments: [workingPath]) }

        var manifest: KnowledgeSnapshotManifest
        do {
            let working = try OrionDatabase(path: workingPath, mode: .importedSnapshot)
            let store = Store(working)
            try prune(working, keepRepository: repository.id, keepRun: run.id, repositoryName: repositoryName)
            let snippets = try captureSnippets(store: store, runId: run.id)
            try store.insertEvidenceSnippets(snippets.records)
            let counts = try Self.counts(working, snippets: snippets.records.count, skipped: snippets.skipped)

            manifest = KnowledgeSnapshotManifest(
                schemaVersion: OrionMigrations.makeMigrator().migrations.last ?? "",
                libraryKey: libraryKey, repositoryName: repositoryName, sourceURL: repository.sourceURL,
                commitHash: run.commitHash, runId: run.id, analyzedAt: run.startedAt, createdAt: now(),
                orionVersion: OrionCodeIntel.version, counts: counts)
            try working.dbQueue.write { dbc in
                try dbc.execute(
                    sql: "INSERT INTO snapshot_manifest (id, json) VALUES (1, ?)",
                    arguments: [String(decoding: try manifest.json(), as: UTF8.self)])
            }
            // One self-contained file: out of WAL, compacted after the deletes.
            try working.dbQueue.inDatabase { dbc in
                try dbc.execute(sql: "PRAGMA journal_mode = DELETE")
                try dbc.execute(sql: "VACUUM")
            }
            try Self.checkIntegrity(working)
            try working.dbQueue.close()
        }

        let database = try Data(contentsOf: URL(fileURLWithPath: workingPath))
        let compressed = try KnowledgeSnapshotFormat.compress(database)
        let base = name ?? Self.defaultName(repositoryName: repositoryName, commit: run.commitHash)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let snapshotURL = outputDirectory.appendingPathComponent("\(base).\(KnowledgeSnapshotFormat.fileExtension)")
        let manifestURL = outputDirectory.appendingPathComponent("\(base).manifest.json")
        try compressed.write(to: snapshotURL, options: .atomic)

        manifest.databaseByteCount = database.count
        manifest.snapshotByteCount = compressed.count
        manifest.sha256 = KnowledgeSnapshotFormat.sha256Hex(compressed)
        try manifest.json().write(to: manifestURL, options: .atomic)
        return Output(manifest: manifest, snapshotURL: snapshotURL, manifestURL: manifestURL)
    }

    // MARK: - Trimming

    private func prune(_ db: OrionDatabase, keepRepository: String, keepRun: String, repositoryName: String) throws {
        try db.dbQueue.write { dbc in
            try dbc.execute(sql: "DELETE FROM repositories WHERE id <> ?", arguments: [keepRepository])
            try dbc.execute(sql: "DELETE FROM analysis_runs WHERE id <> ?", arguments: [keepRun])
            // The Mac's own learning and asking; the phone keeps its own (Docs/19 decision 4).
            for table in [
                "teaching_attempts", "teaching_misconceptions", "knowledge_states", "ask_sessions",
                // Mac-only traces.
                "routing_decisions", "agent_tool_calls", "diagnostics",
                // A snapshot of a snapshot starts clean.
                "evidence_snippets", "snapshot_manifest",
            ] {
                try dbc.execute(sql: "DELETE FROM \(table)")
            }
            try dbc.execute(sql: "DELETE FROM teaching_questions WHERE verified = 0")
            try dbc.execute(sql: "UPDATE repositories SET local_path = ?", arguments: [repositoryName])
        }
    }

    // MARK: - Snippets

    private struct CitedRange: Hashable {
        let filePath: String
        let start: Int
        let end: Int
    }

    private func captureSnippets(store: Store, runId: String) throws -> (records: [EvidenceSnippetRecord], skipped: Int) {
        let ranges = try citedRanges(store: store, runId: runId)
        let fileHashes = Dictionary(
            try store.files(runId: runId).map { ($0.path, $0.sha256) }, uniquingKeysWith: { first, _ in first })

        var records: [EvidenceSnippetRecord] = []
        var skipped = 0
        for (filePath, fileRanges) in Dictionary(grouping: ranges, by: \.filePath) {
            guard let expected = fileHashes[filePath],
                  let data = try? Data(contentsOf: repoRoot.appendingPathComponent(filePath)),
                  KnowledgeSnapshotFormat.sha256Hex(data) == expected
            else {
                skipped += fileRanges.count
                continue
            }
            let lines = String(decoding: data, as: UTF8.self).components(separatedBy: "\n")
            for range in fileRanges {
                guard let slice = try? EvidenceSlice.slice(
                    lines: lines, start: range.start, end: range.end, maxLines: maxSnippetLines)
                else {
                    skipped += 1
                    continue
                }
                records.append(EvidenceSnippetRecord(
                    filePath: filePath, startLine: range.start, endLine: range.end, firstLine: slice.firstLine,
                    text: slice.lines.joined(separator: "\n"), truncated: slice.truncated, fileSha256: expected))
            }
        }
        return (records.sorted { ($0.filePath, $0.startLine, $0.endLine) < ($1.filePath, $1.startLine, $1.endLine) }, skipped)
    }

    /// Every (file, range) an evidence view can ask for in the kept run.
    private func citedRanges(store: Store, runId: String) throws -> Set<CitedRange> {
        var ranges: Set<CitedRange> = []
        func add(_ anchor: String, _ start: Int?, _ end: Int?) {
            guard let start, let end, start >= 1, end >= start else { return }
            ranges.insert(CitedRange(filePath: EvidenceSlice.filePath(forAnchor: anchor), start: start, end: end))
        }
        try store.db.dbQueue.read { dbc in
            // Claim evidence (component detail, Ask answers).
            for row in try Row.fetchAll(dbc, sql: "SELECT anchor, start_line, end_line FROM evidence") {
                add(row["anchor"], row["start_line"], row["end_line"])
            }
            // Semantic component members (component detail).
            for row in try Row.fetchAll(dbc, sql: """
                SELECT s.anchor, s.start_line, s.end_line
                FROM component_members m JOIN symbols s ON s.id = m.symbol_id
                """) {
                add(row["anchor"], row["start_line"], row["end_line"])
            }
        }
        // Teaching: the kept questions' reference anchors and their criteria's evidence anchors,
        // resolved to symbol ranges the way `TeachingLoader.gradeCard` resolves them.
        var anchors: Set<String> = []
        for question in try store.db.dbQueue.read({ try TeachingQuestionRecord.fetchAll($0) }) {
            anchors.formUnion(question.referenceAnchors)
            for criterion in try store.teachingRubricCriteria(questionId: question.id) {
                anchors.formUnion(criterion.evidenceAnchors)
            }
        }
        for anchor in anchors {
            if let symbol = try store.symbol(runId: runId, anchor: anchor) {
                add(anchor, symbol.startLine, symbol.endLine)
            }
        }
        return ranges
    }

    // MARK: - Checks and naming

    private static func counts(_ db: OrionDatabase, snippets: Int, skipped: Int) throws -> KnowledgeSnapshotManifest.Counts {
        try db.dbQueue.read { dbc in
            func count(_ table: String) throws -> Int {
                try Int.fetchOne(dbc, sql: "SELECT COUNT(*) FROM \(table)") ?? 0
            }
            return KnowledgeSnapshotManifest.Counts(
                files: try count("files"), symbols: try count("symbols"),
                relationships: try count("relationships"), components: try count("components"),
                claims: try count("claims"), evidence: try count("evidence"),
                modelRevisions: try count("model_revisions"), teachingConcepts: try count("teaching_concepts"),
                teachingQuestions: try count("teaching_questions"), snippets: snippets, snippetsSkipped: skipped)
        }
    }

    private static func checkIntegrity(_ db: OrionDatabase) throws {
        try db.dbQueue.read { dbc in
            let integrity = try String.fetchAll(dbc, sql: "PRAGMA integrity_check")
            guard integrity == ["ok"] else {
                throw BuildError.integrityCheckFailed(integrity.joined(separator: "; "))
            }
            let violations = try Row.fetchAll(dbc, sql: "PRAGMA foreign_key_check")
            guard violations.isEmpty else {
                throw BuildError.integrityCheckFailed("\(violations.count) foreign key violation(s)")
            }
        }
    }

    static func defaultName(repositoryName: String, commit: String) -> String {
        let safe = repositoryName.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "-" }
        return "\(String(safe))-\(commit.prefix(12))"
    }
}
