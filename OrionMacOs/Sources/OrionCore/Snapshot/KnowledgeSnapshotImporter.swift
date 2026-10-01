import Foundation
import GRDB

/// Installs a knowledge snapshot into the device's `LocalLibrary` (Docs/19 M3), keeping what the
/// device learned from the one it replaces.
///
/// A snapshot carries the Mac's knowledge and none of its learning (M2). Everything the device
/// wrote itself -- teaching attempts, mastery, misconceptions, the questions it drafted, its ask
/// sessions and their answers -- lives in the same database, so a re-import rebuilds that database
/// from the new snapshot and **carries the device's rows across**:
///
/// - **Concepts are matched by natural key** (`kind` + `subject_label`), never by id: ids include
///   `repository_id`, which changes when the Mac re-analyzes at a new commit. A concept the new
///   snapshot no longer has, but the device has progress on, is kept, marked `stale`.
/// - **Questions:** one the new snapshot still has is the Mac's; the device's attempts point at it
///   unchanged. One it lacks is carried if the device drafted it (`generated_by = device`) or has
///   attempts on it -- the Mac may have dropped a question the learner already answered.
/// - **Asks:** every ask session, its turns, and the investigations behind them (with their claims,
///   evidence, routing decisions, tool calls and the model revisions they triggered), re-homed onto
///   the new snapshot's repository, run and commit. Links into the analysis that no longer resolve
///   (a file or symbol id from the old run, a vanished component) are cleared rather than dropped.
///   Carried revisions are re-chained after the Mac's newest one.
/// - Anything whose parent can't be found is counted in `Report.orphaned`, never silently kept
///   dangling: the result passes `foreign_key_check`.
///
/// The swap is atomic: the new database is built beside the old one and replaces it in one step,
/// so an interrupted import leaves the previous state intact. No connection to the library's
/// database may be open while importing.
public struct KnowledgeSnapshotImporter {
    public let library: LocalLibrary

    public init(library: LocalLibrary) {
        self.library = library
    }

    public enum ImportError: Error, LocalizedError, Equatable {
        case notASnapshot(String)
        case checksumMismatch(expected: String, actual: String)
        case unsupportedFormat(Int)
        case libraryKeyMismatch(expected: String, actual: String)
        case integrityCheckFailed(String)

        public var errorDescription: String? {
            switch self {
            case .notASnapshot(let detail): return "This file isn't an Orion knowledge snapshot (\(detail))."
            case .checksumMismatch: return "The snapshot was damaged in transfer (checksum mismatch). Sync again."
            case .unsupportedFormat(let version):
                return "This snapshot uses format \(version), newer than this version of Orion reads. Update Orion."
            case .libraryKeyMismatch: return "The snapshot doesn't belong to the repository it was sent for."
            case .integrityCheckFailed(let detail): return "The imported knowledge failed its integrity check: \(detail)"
            }
        }
    }

    public struct Report: Equatable, Sendable {
        public var manifest: KnowledgeSnapshotManifest
        /// `false` for a repository new to this device.
        public var replacedExisting: Bool
        /// The snapshot's schema before this app migrated it up; equal to `manifest.schemaVersion`
        /// when nothing needed migrating.
        public var migratedFromSchema: String
        /// Rows carried from the previous database, per table.
        public var carried: [String: Int]
        /// Previous rows whose parents are gone, per table.
        public var orphaned: [String: Int]
        /// Concepts the device has progress on that the new snapshot dropped, kept as stale.
        public var staleConceptsKept: Int
    }

    /// Imports `snapshotURL`. `expected` is the manifest that travelled with it (the CloudKit
    /// record, or a `.manifest.json`); when given, the file's size and hash must match it.
    @discardableResult
    public func importSnapshot(at snapshotURL: URL, expected: KnowledgeSnapshotManifest? = nil) throws -> Report {
        let file = try Data(contentsOf: snapshotURL)
        let sha = KnowledgeSnapshotFormat.sha256Hex(file)
        if let expectedSha = expected?.sha256, expectedSha != sha {
            throw ImportError.checksumMismatch(expected: expectedSha, actual: sha)
        }
        let database: Data
        do {
            database = try KnowledgeSnapshotFormat.decompress(file)
        } catch {
            throw ImportError.notASnapshot("not lzfse-compressed")
        }

        try FileManager.default.createDirectory(at: library.root, withIntermediateDirectories: true)
        let incomingURL = library.root.appendingPathComponent(".incoming-\(UUID().uuidString).db")
        defer { Self.removeDatabaseFiles(at: incomingURL) }
        try database.write(to: incomingURL)

        let schemaBefore = try Self.lastAppliedMigration(at: incomingURL)
        let incoming = try OrionDatabase(path: incomingURL.path, mode: .importedSnapshot)
        guard var manifest = try Store(incoming).snapshotManifest() else {
            throw ImportError.notASnapshot("no embedded manifest")
        }
        guard manifest.formatVersion <= KnowledgeSnapshotFormat.formatVersion else {
            throw ImportError.unsupportedFormat(manifest.formatVersion)
        }
        if let expectedKey = expected?.libraryKey, expectedKey != manifest.libraryKey {
            throw ImportError.libraryKeyMismatch(expected: expectedKey, actual: manifest.libraryKey)
        }
        manifest.databaseByteCount = database.count
        manifest.snapshotByteCount = file.count
        manifest.sha256 = sha

        let destination = library.databaseURL(for: manifest.libraryKey)
        let replacing = FileManager.default.fileExists(atPath: destination.path)
        var report = Report(
            manifest: manifest, replacedExisting: replacing, migratedFromSchema: schemaBefore ?? manifest.schemaVersion,
            carried: [:], orphaned: [:], staleConceptsKept: 0)

        if replacing {
            // Bring the previous database up to this app's schema and fold its WAL in, so it can
            // be attached as one consistent file.
            let previous = try OrionDatabase(path: destination.path, mode: .importedSnapshot)
            try previous.dbQueue.writeWithoutTransaction { try $0.execute(sql: "PRAGMA wal_checkpoint(TRUNCATE)") }
            try previous.dbQueue.close()
            try LearnerCarryOver.run(into: incoming, from: destination, report: &report)
        }

        try incoming.dbQueue.writeWithoutTransaction { dbc in
            try dbc.execute(sql: "PRAGMA journal_mode = DELETE")
        }
        try Self.checkIntegrity(incoming)
        try incoming.dbQueue.close()

        // Swap: manifest first (harmless if the swap then fails), then the database in one step.
        let folder = library.folder(for: manifest.libraryKey)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try manifest.json().write(to: library.manifestURL(for: manifest.libraryKey), options: .atomic)
        if replacing {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: incomingURL)
        } else {
            try FileManager.default.moveItem(at: incomingURL, to: destination)
        }
        for suffix in ["-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: destination.path + suffix)
        }
        return report
    }

    // MARK: - Helpers

    private static func lastAppliedMigration(at url: URL) throws -> String? {
        let queue = try DatabaseQueue(path: url.path)
        defer { try? queue.close() }
        let applied = try queue.read { try OrionMigrations.makeMigrator().appliedIdentifiers($0) }
        return OrionMigrations.makeMigrator().migrations.last { applied.contains($0) }
    }

    private static func checkIntegrity(_ db: OrionDatabase) throws {
        try db.dbQueue.read { dbc in
            let integrity = try String.fetchAll(dbc, sql: "PRAGMA integrity_check")
            guard integrity == ["ok"] else {
                throw ImportError.integrityCheckFailed(integrity.joined(separator: "; "))
            }
            let violations = try Row.fetchAll(dbc, sql: "PRAGMA foreign_key_check")
            guard violations.isEmpty else {
                throw ImportError.integrityCheckFailed(
                    "\(violations.count) foreign key violation(s), first in \(violations[0]["table"] as String? ?? "?")")
            }
        }
    }

    private static func removeDatabaseFiles(at url: URL) {
        for suffix in ["", "-wal", "-shm", "-journal"] {
            try? FileManager.default.removeItem(atPath: url.path + suffix)
        }
    }
}

/// The carry-over itself: SQL from the previous database (attached as `old`) into the incoming
/// snapshot (`main`), table by table, parents before children.
enum LearnerCarryOver {
    static func run(into incoming: OrionDatabase, from previousURL: URL, report: inout KnowledgeSnapshotImporter.Report) throws {
        try incoming.dbQueue.writeWithoutTransaction { dbc in
            try dbc.execute(sql: "ATTACH DATABASE ? AS old", arguments: [previousURL.path])
            defer { try? dbc.execute(sql: "DETACH DATABASE old") }
            try dbc.inTransaction {
                try carry(dbc, report: &report)
                return .commit
            }
        }
    }

    private static func carry(_ db: Database, report: inout KnowledgeSnapshotImporter.Report) throws {
        // The one repository/run/commit a snapshot holds: where carried rows are re-homed.
        try db.execute(sql: """
            CREATE TEMP TABLE carry_ctx AS
            SELECT a.repository_id AS repo, a.id AS run, a.commit_hash AS commit_hash
            FROM main.analysis_runs a LIMIT 1
            """)
        let repo = "(SELECT repo FROM temp.carry_ctx)"
        let run = "(SELECT run FROM temp.carry_ctx)"
        let commit = "(SELECT commit_hash FROM temp.carry_ctx)"
        func keep(_ column: String, ifIn table: String) -> String {
            "CASE WHEN src.\(column) IN (SELECT id FROM main.\(table)) THEN src.\(column) END"
        }

        // --- Teaching -------------------------------------------------------------------------

        // Questions the new snapshot lacks but the device needs: its own drafts, and any question
        // it has attempts on.
        try db.execute(sql: """
            CREATE TEMP TABLE carried_questions AS
            SELECT id FROM old.teaching_questions
            WHERE id NOT IN (SELECT id FROM main.teaching_questions)
              AND (generated_by = '\(TeachingQuestionSource.device.rawValue)'
                   OR id IN (SELECT question_id FROM old.teaching_attempts))
            """)

        // Old concept -> new concept by natural key. A concept the device has progress on (a
        // knowledge state, or a carried question) that the Mac dropped is kept as stale.
        try db.execute(sql: """
            CREATE TEMP TABLE concept_map AS
            SELECT o.id AS old_id, n.id AS new_id
            FROM old.teaching_concepts o
            JOIN main.teaching_concepts n ON n.kind = o.kind AND n.subject_label = o.subject_label
            """)
        try db.execute(sql: """
            CREATE TEMP TABLE needed_concepts AS
            SELECT concept_id AS id FROM old.knowledge_states
            UNION SELECT concept_id FROM old.teaching_questions WHERE id IN (SELECT id FROM temp.carried_questions)
            """)
        report.staleConceptsKept = try copy(
            db, "teaching_concepts",
            where: """
                src.id IN (SELECT id FROM temp.needed_concepts)
                AND src.id NOT IN (SELECT old_id FROM temp.concept_map)
                """,
            overrides: [
                "repository_id": repo, "stale": "1",
                "source_component_id": "NULL", "source_claim_id": "NULL",
            ])
        try db.execute(sql: """
            INSERT INTO temp.concept_map
            SELECT id, id FROM old.teaching_concepts
            WHERE id IN (SELECT id FROM temp.needed_concepts)
              AND id NOT IN (SELECT old_id FROM temp.concept_map)
            """)
        let mappedConcept = "(SELECT new_id FROM temp.concept_map WHERE old_id = src.concept_id)"

        report.carried["teaching_questions"] = try copy(
            db, "teaching_questions", where: "src.id IN (SELECT id FROM temp.carried_questions)",
            overrides: ["concept_id": mappedConcept, "investigation_id": keep("investigation_id", ifIn: "investigations")])
        report.carried["teaching_rubric_criteria"] = try copy(
            db, "teaching_rubric_criteria", where: "src.question_id IN (SELECT id FROM temp.carried_questions)")
        report.carried["teaching_attempts"] = try copy(
            db, "teaching_attempts", where: "src.question_id IN (SELECT id FROM main.teaching_questions)")
        report.carried["teaching_criterion_results"] = try copy(
            db, "teaching_criterion_results",
            where: """
                src.attempt_id IN (SELECT id FROM main.teaching_attempts)
                AND src.criterion_id IN (SELECT id FROM main.teaching_rubric_criteria)
                """)
        report.carried["knowledge_states"] = try copy(
            db, "knowledge_states", where: "1", overrides: ["concept_id": mappedConcept])
        report.carried["teaching_misconceptions"] = try copy(
            db, "teaching_misconceptions",
            where: """
                src.knowledge_state_id IN (SELECT id FROM main.knowledge_states)
                AND src.criterion_id IN (SELECT id FROM main.teaching_rubric_criteria)
                AND src.attempt_id IN (SELECT id FROM main.teaching_attempts)
                """)

        // --- Asking ---------------------------------------------------------------------------

        // The device's own investigations: the ones behind its ask turns and routing decisions
        // (a session-less ask has only the latter).
        try db.execute(sql: """
            CREATE TEMP TABLE carried_investigations AS
            SELECT id FROM old.investigations
            WHERE id NOT IN (SELECT id FROM main.investigations)
              AND (id IN (SELECT investigation_id FROM old.ask_session_turns)
                   OR id IN (SELECT investigation_id FROM old.routing_decisions))
            """)
        let rehome = ["repository_id": repo, "run_id": run, "commit_hash": commit]
        report.carried["investigations"] = try copy(
            db, "investigations", where: "src.id IN (SELECT id FROM temp.carried_investigations)", overrides: rehome)
        report.carried["claims"] = try copy(
            db, "claims", where: "src.investigation_id IN (SELECT id FROM temp.carried_investigations)",
            overrides: rehome)
        report.carried["evidence"] = try copy(
            db, "evidence",
            where: """
                src.claim_id IN (SELECT id FROM old.claims
                                 WHERE investigation_id IN (SELECT id FROM temp.carried_investigations))
                """,
            overrides: ["file_id": keep("file_id", ifIn: "files"), "symbol_id": keep("symbol_id", ifIn: "symbols")])
        report.carried["routing_decisions"] = try copy(
            db, "routing_decisions", where: "src.investigation_id IN (SELECT id FROM temp.carried_investigations)")
        report.carried["agent_tool_calls"] = try copy(
            db, "agent_tool_calls", where: "src.investigation_id IN (SELECT id FROM temp.carried_investigations)")
        // A component-scoped session whose component is gone keeps its history as a repository-wide one.
        report.carried["ask_sessions"] = try copy(
            db, "ask_sessions", where: "1",
            overrides: [
                "repository_id": repo, "commit_hash": commit,
                "component_id": keep("component_id", ifIn: "components"),
                "scope_type": """
                    CASE WHEN src.component_id IS NOT NULL AND src.component_id NOT IN (SELECT id FROM main.components)
                    THEN '\(AskSessionScope.repository.rawValue)' ELSE src.scope_type END
                    """,
            ])
        report.carried["ask_session_turns"] = try copy(
            db, "ask_session_turns",
            where: """
                src.session_id IN (SELECT id FROM main.ask_sessions)
                AND src.investigation_id IN (SELECT id FROM main.investigations)
                """)

        // Revisions the device's answers triggered, re-chained after the Mac's newest.
        report.carried["model_revisions"] = try copy(
            db, "model_revisions",
            where: "src.triggering_investigation_id IN (SELECT id FROM temp.carried_investigations)",
            overrides: ["repository_id": repo, "previous_revision": "NULL"])
        report.carried["model_revision_entries"] = try copy(
            db, "model_revision_entries",
            where: """
                src.model_revision_id IN (SELECT id FROM old.model_revisions
                                          WHERE triggering_investigation_id IN (SELECT id FROM temp.carried_investigations))
                """,
            overrides: ["related_claim_id": keep("related_claim_id", ifIn: "claims")])
        try rechainRevisions(db)

        // --- What couldn't come across --------------------------------------------------------

        for table in [
            "teaching_attempts", "teaching_criterion_results", "knowledge_states", "teaching_misconceptions",
            "ask_sessions", "ask_session_turns",
        ] {
            let before = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM old.\(table)") ?? 0
            let lost = before - (report.carried[table] ?? 0)
            if lost > 0 { report.orphaned[table] = lost }
        }
        report.carried = report.carried.filter { $0.value > 0 }

        for table in ["carry_ctx", "carried_questions", "concept_map", "needed_concepts", "carried_investigations"] {
            try db.execute(sql: "DROP TABLE temp.\(table)")
        }
    }

    /// Copies `old.<table>` rows matching `condition` (over alias `src`) into `main.<table>`, every
    /// column verbatim except `overrides` (SQL expressions over `src`). Returns the rows copied.
    private static func copy(
        _ db: Database, _ table: String, where condition: String, overrides: [String: String] = [:]
    ) throws -> Int {
        let columns = try db.columns(in: table, in: "main").map(\.name)
        let select = columns.map { overrides[$0] ?? "src.\($0)" }.joined(separator: ", ")
        try db.execute(sql: """
            INSERT INTO main.\(table) (\(columns.joined(separator: ", ")))
            SELECT \(select) FROM old.\(table) AS src WHERE \(condition)
            """)
        return db.changesCount
    }

    /// Carried revisions (`previous_revision` still NULL, triggered by a carried investigation) are
    /// numbered and linked after the newest revision the snapshot itself has, in creation order.
    private static func rechainRevisions(_ db: Database) throws {
        let carried = try Row.fetchAll(db, sql: """
            SELECT id FROM main.model_revisions
            WHERE triggering_investigation_id IN (SELECT id FROM temp.carried_investigations)
            ORDER BY created_at, id
            """).map { $0["id"] as String }
        guard !carried.isEmpty else { return }
        let placeholders = carried.map { _ in "?" }.joined(separator: ", ")
        var previous = try Row.fetchOne(db, sql: """
            SELECT id, revision_number FROM main.model_revisions
            WHERE id NOT IN (\(placeholders))
            ORDER BY revision_number DESC, created_at DESC LIMIT 1
            """, arguments: StatementArguments(carried))
        for id in carried {
            let number = (previous?["revision_number"] as Int? ?? 0) + 1
            try db.execute(
                sql: "UPDATE main.model_revisions SET previous_revision = ?, revision_number = ? WHERE id = ?",
                arguments: [previous?["id"] as String?, number, id])
            previous = try Row.fetchOne(
                db, sql: "SELECT id, revision_number FROM main.model_revisions WHERE id = ?", arguments: [id])
        }
    }
}
