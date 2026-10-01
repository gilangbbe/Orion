import CryptoKit
import Foundation
import GRDB

/// A knowledge snapshot (Docs/19 M2): the Mac's Codebase Model for one repository, trimmed to what
/// the iOS companion explores and learns from, as one lzfse-compressed SQLite file.
///
/// The format types live here, in portable `OrionCore`, because both ends need them: the Mac's
/// `KnowledgeSnapshotBuilder` writes a snapshot, and the phone's importer (M3) reads one.
public enum KnowledgeSnapshotFormat {
    /// Bumped when the *container* changes (compression, manifest shape). Schema changes inside
    /// the database are migrations, which the importer applies itself.
    public static let formatVersion = 1
    public static let fileExtension = "orionsnap"

    /// The snapshot file's bytes: the SQLite database, lzfse-compressed.
    public static func compress(_ database: Data) throws -> Data {
        try (database as NSData).compressed(using: .lzfse) as Data
    }

    public static func decompress(_ snapshot: Data) throws -> Data {
        try (snapshot as NSData).decompressed(using: .lzfse) as Data
    }

    /// Lowercase hex SHA-256, the same form as `files.sha256`.
    public static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// A stable id for one repository's snapshots across commits and re-analyses: its source URL
    /// when it was cloned, else its checkout path on the Mac. It names the CloudKit record (M5) and
    /// the phone's library folder (M3), so the path itself never leaves the Mac.
    public static func libraryKey(sourceURL: String?, localPath: String) -> String {
        let identity = sourceURL.flatMap { $0.isEmpty ? nil : $0 } ?? localPath
        return String(sha256Hex(Data(identity.utf8)).prefix(24))
    }
}

/// What a snapshot contains. Stored inside the database (`snapshot_manifest`) and written next to
/// the file as `<name>.manifest.json`; only the outside copy has the compressed size and hash,
/// which can't be known from inside the file they describe.
public struct KnowledgeSnapshotManifest: Codable, Equatable, Sendable {
    public var formatVersion: Int
    /// The last schema migration the database has, e.g. `v7_ios_snapshot`.
    public var schemaVersion: String
    public var libraryKey: String
    public var repositoryName: String
    public var sourceURL: String?
    public var commitHash: String
    public var runId: String
    /// When the snapshotted analysis run started (`analysis_runs.started_at`).
    public var analyzedAt: String
    public var createdAt: String
    public var orionVersion: String
    public var counts: Counts
    /// The database's size, and the `.orionsnap` file's size and SHA-256. `nil` in the embedded
    /// copy, which is written before the file it describes is final.
    public var databaseByteCount: Int?
    public var snapshotByteCount: Int?
    public var sha256: String?

    public struct Counts: Codable, Equatable, Sendable {
        public var files: Int
        public var symbols: Int
        public var relationships: Int
        public var components: Int
        public var claims: Int
        public var evidence: Int
        public var modelRevisions: Int
        public var teachingConcepts: Int
        public var teachingQuestions: Int
        public var snippets: Int
        /// Cited ranges with no snippet: the file changed since the analysis (sha mismatch), was
        /// missing, or the range didn't exist in it.
        public var snippetsSkipped: Int

        public init(
            files: Int, symbols: Int, relationships: Int, components: Int, claims: Int, evidence: Int,
            modelRevisions: Int, teachingConcepts: Int, teachingQuestions: Int, snippets: Int,
            snippetsSkipped: Int
        ) {
            self.files = files
            self.symbols = symbols
            self.relationships = relationships
            self.components = components
            self.claims = claims
            self.evidence = evidence
            self.modelRevisions = modelRevisions
            self.teachingConcepts = teachingConcepts
            self.teachingQuestions = teachingQuestions
            self.snippets = snippets
            self.snippetsSkipped = snippetsSkipped
        }
    }

    public init(
        formatVersion: Int = KnowledgeSnapshotFormat.formatVersion, schemaVersion: String,
        libraryKey: String, repositoryName: String, sourceURL: String?, commitHash: String,
        runId: String, analyzedAt: String, createdAt: String, orionVersion: String, counts: Counts,
        databaseByteCount: Int? = nil, snapshotByteCount: Int? = nil, sha256: String? = nil
    ) {
        self.formatVersion = formatVersion
        self.schemaVersion = schemaVersion
        self.libraryKey = libraryKey
        self.repositoryName = repositoryName
        self.sourceURL = sourceURL
        self.commitHash = commitHash
        self.runId = runId
        self.analyzedAt = analyzedAt
        self.createdAt = createdAt
        self.orionVersion = orionVersion
        self.counts = counts
        self.databaseByteCount = databaseByteCount
        self.snapshotByteCount = snapshotByteCount
        self.sha256 = sha256
    }

    public func json() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    public static func decode(_ data: Data) throws -> KnowledgeSnapshotManifest {
        try JSONDecoder().decode(KnowledgeSnapshotManifest.self, from: data)
    }
}

/// One `evidence_snippets` row: a cited range's source lines, captured on the Mac.
public struct EvidenceSnippetRecord: OrionRecord, Equatable, Sendable {
    public static let databaseTableName = "evidence_snippets"

    public var filePath: String
    /// The cited range, as an evidence view asks for it.
    public var startLine: Int
    public var endLine: Int
    /// The line number of `text`'s first line (the range plus context).
    public var firstLine: Int
    public var text: String
    /// `text` stops before the range plus context does (`EvidenceSlice` cap).
    public var truncated: Bool
    public var fileSha256: String

    public init(
        filePath: String, startLine: Int, endLine: Int, firstLine: Int, text: String, truncated: Bool,
        fileSha256: String
    ) {
        self.filePath = filePath
        self.startLine = startLine
        self.endLine = endLine
        self.firstLine = firstLine
        self.text = text
        self.truncated = truncated
        self.fileSha256 = fileSha256
    }
}

/// The one implementation of "which lines does an evidence view show": the Mac's
/// `EvidenceSourceLoader` (whole checkout) and `KnowledgeSnapshotBuilder` (snippets for the phone)
/// both slice with it, so a snippet is exactly what the Mac would have shown -- up to the cap.
public enum EvidenceSlice {
    public static let defaultContextLines = 3
    /// The snapshot's per-snippet cap. A cited class can span hundreds of lines; the phone shows
    /// the head of it and says it was cut.
    public static let snapshotMaxLines = 80

    public struct Slice: Equatable, Sendable {
        public let firstLine: Int
        public let lines: [String]
        /// `nil` for a range-less anchor (shown whole, nothing highlighted).
        public let highlight: ClosedRange<Int>?
        public let truncated: Bool

        public init(firstLine: Int, lines: [String], highlight: ClosedRange<Int>?, truncated: Bool) {
            self.firstLine = firstLine
            self.lines = lines
            self.highlight = highlight
            self.truncated = truncated
        }
    }

    public enum SliceError: Error, Equatable {
        case invalidRange
    }

    /// An anchor's file: everything before `::` (`path/to/mod.py::Class.method` → `path/to/mod.py`).
    public static func filePath(forAnchor anchor: String) -> String {
        String(anchor.split(separator: "::", maxSplits: 1).first ?? Substring(anchor))
    }

    /// `lines` (a file split on `\n`) cut to `start...end` with `context` lines either side, or
    /// the first `maxLinesWithNoRange` lines when there's no valid range. `maxLines` caps a ranged
    /// slice (`nil`: uncapped, the Mac's own view).
    public static func slice(
        lines: [String], start: Int?, end: Int?, context: Int = defaultContextLines,
        maxLines: Int? = nil, maxLinesWithNoRange: Int = 200
    ) throws -> Slice {
        guard let start, let end, start >= 1, end >= start else {
            let head = Array(lines.prefix(maxLinesWithNoRange))
            return Slice(firstLine: 1, lines: head, highlight: nil, truncated: lines.count > head.count)
        }
        guard start <= lines.count else { throw SliceError.invalidRange }
        let lower = max(1, start - context)
        let upper = min(lines.count, end + context)
        var slice = Array(lines[(lower - 1)..<upper])
        var truncated = false
        if let maxLines, slice.count > maxLines {
            slice = Array(slice.prefix(maxLines))
            truncated = true
        }
        return Slice(firstLine: lower, lines: slice, highlight: start...end, truncated: truncated)
    }
}
