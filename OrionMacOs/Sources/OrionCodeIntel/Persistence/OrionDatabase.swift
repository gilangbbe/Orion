import Foundation
import GRDB

/// Opens (creating if needed) the Code Graph SQLite database and runs migrations.
/// CLI uses a single-writer `DatabaseQueue`; a future app can swap in a `DatabasePool`.
public final class OrionDatabase {
    public let dbQueue: DatabaseQueue
    public let path: String

    public init(path: String) throws {
        self.path = path
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: path).deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        var config = Configuration()
        config.foreignKeysEnabled = true
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA journal_mode = WAL;")
            try db.execute(sql: "PRAGMA synchronous = NORMAL;")
        }

        self.dbQueue = try DatabaseQueue(path: path, configuration: config)
        try OrionMigrations.makeMigrator().migrate(dbQueue)
    }

    /// In-memory database, for tests.
    public init(inMemory: Bool) throws {
        precondition(inMemory)
        self.path = ":memory:"
        var config = Configuration()
        config.foreignKeysEnabled = true
        self.dbQueue = try DatabaseQueue(configuration: config)
        try OrionMigrations.makeMigrator().migrate(dbQueue)
    }
}
