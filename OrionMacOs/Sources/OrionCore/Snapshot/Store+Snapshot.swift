import Foundation
import GRDB

/// `Store` access to the two snapshot-only tables (Docs/19 M2, `v7_ios_snapshot`).
extension Store {
    public func insertEvidenceSnippets(_ records: [EvidenceSnippetRecord]) throws {
        try db.dbQueue.write { dbc in
            for record in records { try record.insert(dbc, onConflict: .ignore) }
        }
    }

    /// The snippet for exactly this cited range -- how an evidence view on the phone finds its
    /// lines. `nil` when the snapshot carries none (a structural-only member, or a file that had
    /// changed since the analysis).
    public func evidenceSnippet(filePath: String, startLine: Int, endLine: Int) throws -> EvidenceSnippetRecord? {
        try db.dbQueue.read { dbc in
            try EvidenceSnippetRecord
                .filter(Column("file_path") == filePath && Column("start_line") == startLine
                    && Column("end_line") == endLine)
                .fetchOne(dbc)
        }
    }

    /// What an evidence view shows for `anchor`'s cited range, from the snapshot's snippets -- the
    /// phone's counterpart of the Mac reading the checkout (Docs/19 M3). The same `Slice` shape the
    /// Mac's `EvidenceSlice` produces, so one view renders both. `nil` when the snapshot has no
    /// snippet for that range (or the anchor has no range).
    public func evidenceSlice(anchor: String, startLine: Int?, endLine: Int?) throws -> EvidenceSlice.Slice? {
        guard let startLine, let endLine,
              let snippet = try evidenceSnippet(
                  filePath: EvidenceSlice.filePath(forAnchor: anchor), startLine: startLine, endLine: endLine)
        else { return nil }
        return EvidenceSlice.Slice(
            firstLine: snippet.firstLine, lines: snippet.text.components(separatedBy: "\n"),
            highlight: startLine...endLine, truncated: snippet.truncated)
    }

    public func evidenceSnippetCount() throws -> Int {
        try db.dbQueue.read { try EvidenceSnippetRecord.fetchCount($0) }
    }

    /// The manifest a snapshot carries inside itself; `nil` on a Mac analysis database.
    public func snapshotManifest() throws -> KnowledgeSnapshotManifest? {
        let json = try db.dbQueue.read { try String.fetchOne($0, sql: "SELECT json FROM snapshot_manifest WHERE id = 1") }
        return try json.map { try KnowledgeSnapshotManifest.decode(Data($0.utf8)) }
    }
}
