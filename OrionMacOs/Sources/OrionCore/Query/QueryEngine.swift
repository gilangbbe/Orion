import Foundation
import GRDB

/// Read-only ad-hoc queries over a Code Graph DB. Backs `orion-index query`; a debugging
/// aid, not a product surface.
public struct QueryEngine {
    public let db: OrionDatabase
    public init(_ db: OrionDatabase) { self.db = db }

    public struct SymbolHit: Encodable, Equatable {
        public var anchor, kind, qualifiedName, file: String
        public var startLine, endLine: Int
        public var isExported: Bool
    }

    public struct EdgeHit: Encodable, Equatable {
        public var type, confidenceTier: String
        public var anchor, ref: String?
        public var external: Bool
        public var siteLine: Int?
    }

    private func runId(commit: String?) throws -> String? {
        try Store(db).latestRun(commitHash: commit)?.id
    }

    public func findSymbols(matching needle: String, commit: String?, limit: Int) throws -> [SymbolHit] {
        guard let rid = try runId(commit: commit) else { return [] }
        let like = "%\(needle)%"
        return try db.dbQueue.read { dbc in
            try Row.fetchAll(dbc, sql: """
                SELECT s.anchor, s.kind, s.qualified_name AS qn, f.path AS file,
                       s.start_line AS sl, s.end_line AS el, s.is_exported AS exp
                FROM symbols s JOIN files f ON f.id = s.file_id
                WHERE s.run_id = ? AND (s.anchor LIKE ? OR s.qualified_name LIKE ?)
                ORDER BY s.qualified_name LIMIT ?
                """, arguments: [rid, like, like, limit]
            ).map {
                SymbolHit(
                    anchor: $0["anchor"], kind: $0["kind"], qualifiedName: $0["qn"],
                    file: $0["file"], startLine: $0["sl"], endLine: $0["el"],
                    isExported: ($0["exp"] as Int) == 1
                )
            }
        }
    }

    public func moduleSymbols(_ dotted: String, commit: String?, limit: Int) throws -> [SymbolHit] {
        guard let rid = try runId(commit: commit) else { return [] }
        return try db.dbQueue.read { dbc in
            try Row.fetchAll(dbc, sql: """
                SELECT s.anchor, s.kind, s.qualified_name AS qn, f.path AS file,
                       s.start_line AS sl, s.end_line AS el, s.is_exported AS exp
                FROM symbols s JOIN files f ON f.id = s.file_id
                WHERE s.run_id = ? AND f.module_path = ?
                ORDER BY s.start_byte LIMIT ?
                """, arguments: [rid, dotted, limit]
            ).map {
                SymbolHit(
                    anchor: $0["anchor"], kind: $0["kind"], qualifiedName: $0["qn"],
                    file: $0["file"], startLine: $0["sl"], endLine: $0["el"],
                    isExported: ($0["exp"] as Int) == 1
                )
            }
        }
    }

    /// Edges whose target is `anchor` (who points at it).
    public func callers(of anchor: String, commit: String?, limit: Int) throws -> [EdgeHit] {
        try edges(anchorColumn: "t.anchor", otherColumn: "s.anchor", anchor: anchor,
                  commit: commit, limit: limit)
    }

    /// Edges whose source is `anchor` (what it points at).
    public func callees(of anchor: String, commit: String?, limit: Int) throws -> [EdgeHit] {
        try edges(anchorColumn: "s.anchor", otherColumn: "t.anchor", anchor: anchor,
                  commit: commit, limit: limit)
    }

    private func edges(
        anchorColumn: String, otherColumn: String, anchor: String, commit: String?, limit: Int
    ) throws -> [EdgeHit] {
        guard let rid = try runId(commit: commit) else { return [] }
        return try db.dbQueue.read { dbc in
            try Row.fetchAll(dbc, sql: """
                SELECT r.relationship_type AS type, r.confidence_tier AS tier,
                       \(otherColumn) AS other, r.target_ref AS ref, r.resolved AS resolved,
                       r.site_start_line AS site
                FROM relationships r
                LEFT JOIN symbols s ON s.id = r.source_symbol_id
                LEFT JOIN symbols t ON t.id = r.target_symbol_id
                WHERE r.run_id = ? AND \(anchorColumn) = ?
                ORDER BY r.relationship_type, other LIMIT ?
                """, arguments: [rid, anchor, limit]
            ).map { row in
                let other: String? = row["other"]
                return EdgeHit(
                    type: row["type"], confidenceTier: row["tier"],
                    anchor: other, ref: other == nil ? row["ref"] : nil,
                    external: other == nil, siteLine: row["site"]
                )
            }
        }
    }
}
