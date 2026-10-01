import Foundation

/// ISO 8601 "now" for every persisted `created_at`/`updated_at`. Lives in `OrionCore` (moved from
/// `Pipeline/StageTimings.swift`, Docs/19 M1) because `OrionAgent` stamps session turns with it and
/// must not depend on the analysis pipeline.
public enum Timestamp {
    private static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    public static func now() -> String { formatter.string(from: Date()) }
}
