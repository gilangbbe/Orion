import CryptoKit
import Foundation

/// Where OrionApp keeps its own shell state -- distinct from any analyzed repository's own
/// `.orion` output directory, which stays wherever `orion-index`'s existing convention puts it
/// (`<repoRoot>/.orion`) so a repo already analyzed via the CLI is picked up by the app with no
/// re-analysis (Docs/13_phase4_architecture_ui.md M1).
enum AppPaths {
    /// `~/Library/Application Support/Orion/`
    static var applicationSupportDirectory: URL {
        let base =
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Orion", isDirectory: true)
    }

    static var clonedRepositoriesDirectory: URL {
        applicationSupportDirectory.appendingPathComponent("repos", isDirectory: true)
    }

    /// A stable, content-addressed destination for cloning `url` -- the same URL always maps to
    /// the same directory, so `RepositoryCloner` can recognize "already cloned" and skip a
    /// redundant network round trip on re-open. Not related to `OrionCodeIntel`'s own
    /// `DeterministicID` (that hashes repository/commit/anchor triples for the Code Graph; this
    /// is purely an app-shell filesystem convenience).
    static func clonedRepositoryDirectory(for url: URL) -> URL {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined().prefix(16)
        let slug = url.deletingPathExtension().lastPathComponent
        let name = slug.isEmpty ? String(hex) : "\(slug)-\(hex)"
        return clonedRepositoriesDirectory.appendingPathComponent(name, isDirectory: true)
    }

    static var recentRepositoriesFile: URL {
        applicationSupportDirectory.appendingPathComponent("recent-repositories.json")
    }
}
