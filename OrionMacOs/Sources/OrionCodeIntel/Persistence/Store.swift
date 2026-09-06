import Foundation
import GRDB

/// Data-access layer over `OrionDatabase`. All bulk writes go through a single write
/// transaction with GRDB's cached prepared statements.
public struct Store {
    public let db: OrionDatabase
    public init(_ db: OrionDatabase) { self.db = db }

    // MARK: Repository

    /// Insert or reuse the `(local_path, commit_hash)` row; always refreshes `updated_at`
    /// and `analysis_status`.
    @discardableResult
    public func upsertRepository(
        localPath: String, commitHash: String, sourceURL: String?,
        languages: [String], status: AnalysisStatus, now: String
    ) throws -> RepositoryRecord {
        try db.dbQueue.write { dbc in
            if var existing = try RepositoryRecord
                .filter(Column("local_path") == localPath && Column("commit_hash") == commitHash)
                .fetchOne(dbc)
            {
                existing.sourceURL = sourceURL ?? existing.sourceURL
                existing.languages = languages
                existing.analysisStatus = status.rawValue
                existing.updatedAt = now
                try existing.update(dbc)
                return existing
            }
            let record = RepositoryRecord(
                id: DeterministicID.newUUID(), sourceURL: sourceURL, localPath: localPath,
                commitHash: commitHash, languages: languages, analysisStatus: status,
                createdAt: now, updatedAt: now
            )
            try record.insert(dbc)
            return record
        }
    }

    public func setRepositoryStatus(id: String, status: AnalysisStatus, now: String) throws {
        try db.dbQueue.write { dbc in
            try dbc.execute(
                sql: "UPDATE repositories SET analysis_status = ?, updated_at = ? WHERE id = ?",
                arguments: [status.rawValue, now, id]
            )
        }
    }

    // MARK: Runs

    public func startRun(
        repositoryId: String, commitHash: String, startedAt: String,
        orionVersion: String, resolver: String, grammarVersions: [String: String]
    ) throws -> AnalysisRunRecord {
        let run = AnalysisRunRecord(
            id: DeterministicID.newUUID(), repositoryId: repositoryId, commitHash: commitHash,
            status: AnalysisStatus.running.rawValue, startedAt: startedAt, finishedAt: nil,
            orionVersion: orionVersion, resolver: resolver, grammarVersions: grammarVersions,
            toolVersions: [:], stageTimings: [:], fileCount: 0, symbolCount: 0,
            relationshipCount: 0, diagnosticCount: 0, error: nil
        )
        try db.dbQueue.write { try run.insert($0) }
        return run
    }

    public func finishRun(_ run: AnalysisRunRecord) throws {
        try db.dbQueue.write { try run.update($0) }
    }

    /// Delete every run (and, via cascade, files/symbols/etc.) for a `(repo, commit)`.
    public func deleteRuns(repositoryId: String, commitHash: String) throws {
        try db.dbQueue.write { dbc in
            try dbc.execute(
                sql: "DELETE FROM analysis_runs WHERE repository_id = ? AND commit_hash = ?",
                arguments: [repositoryId, commitHash]
            )
        }
    }

    // MARK: Bulk inserts

    public func insertFiles(_ records: [FileRecord]) throws {
        guard !records.isEmpty else { return }
        try db.dbQueue.write { dbc in
            for r in records { try r.insert(dbc) }
        }
    }

    public func insertExternalDependencies(_ records: [ExternalDependencyRecord]) throws {
        guard !records.isEmpty else { return }
        try db.dbQueue.write { dbc in
            for r in records { try r.insert(dbc) }
        }
    }

    public func insertSymbols(_ records: [SymbolRecord]) throws {
        guard !records.isEmpty else { return }
        try db.dbQueue.write { dbc in
            // Symbols carry a self-referential parent_symbol_id; defer the check so within-run
            // insert order does not matter (a dangling parent still fails at commit).
            try dbc.execute(sql: "PRAGMA defer_foreign_keys = ON")
            for r in records { try r.insert(dbc) }
        }
    }

    public func insertRelationships(_ records: [RelationshipRecord]) throws {
        guard !records.isEmpty else { return }
        try db.dbQueue.write { dbc in
            try dbc.execute(sql: "PRAGMA defer_foreign_keys = ON")
            for r in records { try r.insert(dbc) }
        }
    }

    public func updateImportCounts(_ counts: [(id: String, count: Int)]) throws {
        guard !counts.isEmpty else { return }
        try db.dbQueue.write { dbc in
            for (id, count) in counts {
                try dbc.execute(
                    sql: "UPDATE external_dependencies SET import_count = ? WHERE id = ?",
                    arguments: [count, id]
                )
            }
        }
    }

    public func insertDiagnostics(_ records: [DiagnosticRecord]) throws {
        guard !records.isEmpty else { return }
        try db.dbQueue.write { dbc in
            for r in records { try r.insert(dbc) }
        }
    }

    public func updateParseOk(fileIds: [String], parseOk: Bool) throws {
        guard !fileIds.isEmpty else { return }
        try db.dbQueue.write { dbc in
            for start in stride(from: 0, to: fileIds.count, by: 500) {
                let chunk = Array(fileIds[start..<min(start + 500, fileIds.count)])
                let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ",")
                var args: [DatabaseValueConvertible] = [parseOk]
                args.append(contentsOf: chunk)
                try dbc.execute(
                    sql: "UPDATE files SET parse_ok = ? WHERE id IN (\(placeholders))",
                    arguments: StatementArguments(args)
                )
            }
        }
    }

    // MARK: Reads (stats)

    public func run(id: String) throws -> AnalysisRunRecord? {
        try db.dbQueue.read { try AnalysisRunRecord.filter(key: id).fetchOne($0) }
    }

    /// The most recent run for a `(repo, commit?)`, preferring `succeeded`.
    public func latestRun(commitHash: String?) throws -> AnalysisRunRecord? {
        try db.dbQueue.read { dbc in
            var request = AnalysisRunRecord.all()
            if let commitHash { request = request.filter(Column("commit_hash") == commitHash) }
            return try request
                .order(
                    SQL("CASE status WHEN 'succeeded' THEN 0 ELSE 1 END").sqlExpression,
                    Column("started_at").desc
                )
                .fetchOne(dbc)
        }
    }

    public func fileLanguageBreakdown(runId: String) throws -> [String: Int] {
        try db.dbQueue.read { dbc in
            let rows = try Row.fetchAll(
                dbc,
                sql: """
                SELECT COALESCE(language, '(none)') AS lang, COUNT(*) AS n
                FROM files WHERE run_id = ? GROUP BY lang
                """,
                arguments: [runId]
            )
            return Dictionary(uniqueKeysWithValues: rows.map { ($0["lang"], $0["n"]) })
        }
    }

    public func count(_ table: String, runId: String) throws -> Int {
        try db.dbQueue.read { dbc in
            try Int.fetchOne(
                dbc, sql: "SELECT COUNT(*) FROM \(table) WHERE run_id = ?", arguments: [runId]
            ) ?? 0
        }
    }

    public func parseOkCount(runId: String) throws -> Int {
        try db.dbQueue.read { dbc in
            try Int.fetchOne(
                dbc, sql: "SELECT COUNT(*) FROM files WHERE run_id = ? AND parse_ok = 1",
                arguments: [runId]
            ) ?? 0
        }
    }

    // MARK: whole-run reads (export)

    public func repository(id: String) throws -> RepositoryRecord? {
        try db.dbQueue.read { try RepositoryRecord.filter(key: id).fetchOne($0) }
    }

    public func files(runId: String) throws -> [FileRecord] {
        try db.dbQueue.read { dbc in
            try FileRecord.filter(Column("run_id") == runId)
                .order(Column("path")).fetchAll(dbc)
        }
    }

    public func symbols(runId: String) throws -> [SymbolRecord] {
        try db.dbQueue.read { dbc in
            try SymbolRecord.filter(Column("run_id") == runId)
                .order(Column("start_byte")).fetchAll(dbc)
        }
    }

    /// Look up one symbol by its exact benchmark-form anchor within a run — the join key
    /// `SemanticImporter` uses to resolve Claude-cited evidence/member anchors
    /// (`UNIQUE(run_id, anchor)`, so at most one match).
    public func symbol(runId: String, anchor: String) throws -> SymbolRecord? {
        try db.dbQueue.read { dbc in
            try SymbolRecord
                .filter(Column("run_id") == runId && Column("anchor") == anchor)
                .fetchOne(dbc)
        }
    }

    public func relationships(runId: String) throws -> [RelationshipRecord] {
        try db.dbQueue.read { dbc in
            try RelationshipRecord.filter(Column("run_id") == runId)
                .order(Column("id")).fetchAll(dbc)
        }
    }

    public func externalDependencies(runId: String) throws -> [ExternalDependencyRecord] {
        try db.dbQueue.read { dbc in
            try ExternalDependencyRecord.filter(Column("run_id") == runId)
                .order(Column("name")).fetchAll(dbc)
        }
    }

    public func diagnostics(runId: String) throws -> [DiagnosticRecord] {
        try db.dbQueue.read { dbc in
            try DiagnosticRecord.filter(Column("run_id") == runId)
                .order(Column("id")).fetchAll(dbc)
        }
    }

    // MARK: Phase 2 — semantic writes (SemanticImporter steps 3-4)

    public func insertInvestigation(_ record: InvestigationRecord) throws {
        try db.dbQueue.write { try record.insert($0) }
    }

    public func insertComponents(_ records: [ComponentRecord]) throws {
        guard !records.isEmpty else { return }
        try db.dbQueue.write { dbc in for r in records { try r.insert(dbc) } }
    }

    public func insertComponentMembers(_ records: [ComponentMemberRecord]) throws {
        guard !records.isEmpty else { return }
        try db.dbQueue.write { dbc in for r in records { try r.insert(dbc) } }
    }

    public func insertComponentRelationships(_ records: [ComponentRelationshipRecord]) throws {
        guard !records.isEmpty else { return }
        try db.dbQueue.write { dbc in for r in records { try r.insert(dbc) } }
    }

    public func insertClaims(_ records: [ClaimRecord]) throws {
        guard !records.isEmpty else { return }
        try db.dbQueue.write { dbc in for r in records { try r.insert(dbc) } }
    }

    public func insertEvidence(_ records: [EvidenceRecord]) throws {
        guard !records.isEmpty else { return }
        try db.dbQueue.write { dbc in for r in records { try r.insert(dbc) } }
    }

    public func insertModelRevision(_ record: ModelRevisionRecord) throws {
        try db.dbQueue.write { try record.insert($0) }
    }

    public func latestModelRevision(repositoryId: String) throws -> ModelRevisionRecord? {
        try db.dbQueue.read { dbc in
            try ModelRevisionRecord.filter(Column("repository_id") == repositoryId)
                .order(Column("created_at").desc).fetchOne(dbc)
        }
    }

    // MARK: Phase 3 — agent writes

    public func insertRoutingDecision(_ record: RoutingDecisionRecord) throws {
        try db.dbQueue.write { try record.insert($0) }
    }

    public func routingDecisions(investigationId: String) throws -> [RoutingDecisionRecord] {
        try db.dbQueue.read { dbc in
            try RoutingDecisionRecord.filter(Column("investigation_id") == investigationId)
                .order(Column("created_at")).fetchAll(dbc)
        }
    }

    public func insertAgentToolCall(_ record: AgentToolCallRecord) throws {
        try db.dbQueue.write { try record.insert($0) }
    }

    public func agentToolCalls(investigationId: String) throws -> [AgentToolCallRecord] {
        try db.dbQueue.read { dbc in
            try AgentToolCallRecord.filter(Column("investigation_id") == investigationId)
                .order(Column("turn_index")).fetchAll(dbc)
        }
    }

    /// Backfill each symbol's single "primary" component membership (Phase 1 reserved this
    /// column; `component_members` stays the many-to-many source of truth).
    public func backfillComponentIds(_ assignments: [(symbolId: String, componentId: String)]) throws {
        guard !assignments.isEmpty else { return }
        try db.dbQueue.write { dbc in
            for a in assignments {
                try dbc.execute(
                    sql: "UPDATE symbols SET component_id = ? WHERE id = ?",
                    arguments: [a.componentId, a.symbolId]
                )
            }
        }
    }

    /// Whether any Phase 1 relationship (any type, either direction) connects a symbol in
    /// `idsA` to a symbol in `idsB` — the structural connectivity check
    /// `SemanticImporter`'s consistency check (step 3) uses to confirm a claimed
    /// component-to-component relationship against the actual Code Graph.
    public func relationshipExists(runId: String, among idsA: [String], and idsB: [String]) throws -> Bool {
        guard !idsA.isEmpty, !idsB.isEmpty else { return false }
        return try db.dbQueue.read { dbc in
            let phA = Array(repeating: "?", count: idsA.count).joined(separator: ",")
            let phB = Array(repeating: "?", count: idsB.count).joined(separator: ",")
            let sql = """
            SELECT COUNT(*) FROM relationships
            WHERE run_id = ?
              AND ((source_symbol_id IN (\(phA)) AND target_symbol_id IN (\(phB)))
                OR (source_symbol_id IN (\(phB)) AND target_symbol_id IN (\(phA))))
            LIMIT 1
            """
            var args: [DatabaseValueConvertible] = [runId]
            args.append(contentsOf: idsA)
            args.append(contentsOf: idsB)
            args.append(contentsOf: idsB)
            args.append(contentsOf: idsA)
            let count = try Int.fetchOne(dbc, sql: sql, arguments: StatementArguments(args)) ?? 0
            return count > 0
        }
    }

    // MARK: Phase 2 — semantic reads (SemanticExporter, M3)

    public func investigations(runId: String) throws -> [InvestigationRecord] {
        try db.dbQueue.read { dbc in
            try InvestigationRecord.filter(Column("run_id") == runId)
                .order(Column("created_at")).fetchAll(dbc)
        }
    }

    /// The most recently-created investigation for a run — "the" current semantic model when
    /// more than one investigation has been ingested over time (M6 repeatability runs).
    public func latestInvestigation(runId: String) throws -> InvestigationRecord? {
        try db.dbQueue.read { dbc in
            try InvestigationRecord.filter(Column("run_id") == runId)
                .order(Column("created_at").desc).fetchOne(dbc)
        }
    }

    public func components(investigationId: String) throws -> [ComponentRecord] {
        try db.dbQueue.read { dbc in
            try ComponentRecord.filter(Column("investigation_id") == investigationId)
                .order(Column("name")).fetchAll(dbc)
        }
    }

    public func componentMembers(componentIds: [String]) throws -> [ComponentMemberRecord] {
        guard !componentIds.isEmpty else { return [] }
        return try db.dbQueue.read { dbc in
            try ComponentMemberRecord.filter(componentIds.contains(Column("component_id")))
                .fetchAll(dbc)
        }
    }

    public func componentRelationships(investigationId: String) throws -> [ComponentRelationshipRecord] {
        try db.dbQueue.read { dbc in
            try ComponentRelationshipRecord.filter(Column("investigation_id") == investigationId)
                .fetchAll(dbc)
        }
    }

    public func claims(investigationId: String) throws -> [ClaimRecord] {
        try db.dbQueue.read { dbc in
            try ClaimRecord.filter(Column("investigation_id") == investigationId)
                .fetchAll(dbc)
        }
    }

    public func evidence(claimIds: [String]) throws -> [EvidenceRecord] {
        guard !claimIds.isEmpty else { return [] }
        return try db.dbQueue.read { dbc in
            try EvidenceRecord.filter(claimIds.contains(Column("claim_id"))).fetchAll(dbc)
        }
    }

    /// Whether any Phase 1 relationship connects two *different* symbols both within `ids` —
    /// the proxy `SemanticImporter` uses to check a claim's evidence symbols actually relate to
    /// each other, rather than being an arbitrary bag of citations (Docs/11 M2).
    public func relationshipExistsAmongAnyPair(runId: String, symbolIds ids: [String]) throws -> Bool {
        guard ids.count >= 2 else { return false }
        return try db.dbQueue.read { dbc in
            let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
            let sql = """
            SELECT COUNT(*) FROM relationships
            WHERE run_id = ? AND source_symbol_id != target_symbol_id
              AND source_symbol_id IN (\(placeholders)) AND target_symbol_id IN (\(placeholders))
            LIMIT 1
            """
            var args: [DatabaseValueConvertible] = [runId]
            args.append(contentsOf: ids)
            args.append(contentsOf: ids)
            let count = try Int.fetchOne(dbc, sql: sql, arguments: StatementArguments(args)) ?? 0
            return count > 0
        }
    }
}
