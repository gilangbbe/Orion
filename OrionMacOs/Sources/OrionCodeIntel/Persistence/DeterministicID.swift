import Foundation
import CryptoKit

/// Stable content-addressed identifiers so re-running the analyzer on the same
/// `(repository, commit)` produces the same file/symbol/relationship ids — JSONL diffs and
/// golden snapshots then mean something. Repository and run ids are random UUIDs (a run is,
/// by definition, a distinct event).
public enum DeterministicID {
    private static let sep = "\u{1f}"   // unit separator, cannot appear in the inputs

    private static func digest(_ parts: [String]) -> String {
        let joined = parts.joined(separator: sep)
        let hash = SHA256.hash(data: Data(joined.utf8))
        return hash.map { String(format: "%02x", $0) }.joined().prefix(32).description
    }

    public static func file(repositoryId: String, commitHash: String, path: String) -> String {
        digest([repositoryId, commitHash, "file", path])
    }

    public static func symbol(
        repositoryId: String, commitHash: String, anchor: String
    ) -> String {
        digest([repositoryId, commitHash, "symbol", anchor])
    }

    public static func relationship(
        repositoryId: String, commitHash: String, type: String,
        source: String, target: String, site: String
    ) -> String {
        digest([repositoryId, commitHash, "rel", type, source, target, site])
    }

    public static func externalDependency(
        repositoryId: String, commitHash: String, name: String
    ) -> String {
        digest([repositoryId, commitHash, "extdep", name])
    }

    public static func diagnostic(
        repositoryId: String, commitHash: String, stage: String, code: String,
        scope: String, ordinal: Int
    ) -> String {
        digest([repositoryId, commitHash, "diag", stage, code, scope, String(ordinal)])
    }

    public static func newUUID() -> String { UUID().uuidString }
}
