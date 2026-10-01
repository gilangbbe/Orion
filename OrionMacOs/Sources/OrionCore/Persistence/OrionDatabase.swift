import Foundation
import GRDB

/// Opens (creating if needed) the Code Graph SQLite database and runs migrations.
/// CLI uses a single-writer `DatabaseQueue`; a future app can swap in a `DatabasePool`.
public final class OrionDatabase {
    public let dbQueue: DatabaseQueue
    public let path: String

    /// How a database file is treated on open (Docs/19 M1).
    public enum OpenMode: Sendable {
        /// A database this machine's analysis produced and can rebuild: DEBUG builds may erase
        /// it when a migration's definition changes (`OrionMigrations.defaultEraseOnSchemaChange`).
        case analysis
        /// A knowledge snapshot synced from the Mac (the iOS companion). Never erased; older
        /// snapshots are migrated up, and one written by a newer Orion is refused.
        case importedSnapshot

        /// What a plain `OrionDatabase(path:)` uses (Docs/19 M4). The Mac analyzes, so `.analysis`;
        /// iOS only ever holds imported snapshots, so `.importedSnapshot`. That way the app's
        /// shared loaders -- which open `<dir>/orion.db` without naming a mode -- can never erase
        /// a device's knowledge in a DEBUG build.
        public static var platformDefault: OpenMode {
            #if os(macOS)
            .analysis
            #else
            .importedSnapshot
            #endif
        }
    }

    public enum OpenError: Error, LocalizedError, Equatable {
        /// The file has migrations this build doesn't know: it was written by a newer Orion.
        case newerSchema(path: String, unknownMigrations: [String])

        public var errorDescription: String? {
            switch self {
            case .newerSchema(_, let unknown):
                return "This knowledge was produced by a newer version of Orion "
                    + "(unknown schema: \(unknown.joined(separator: ", "))). Update Orion to open it."
            }
        }
    }

    public init(path: String, mode: OpenMode = .platformDefault) throws {
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
        switch mode {
        case .analysis:
            try OrionMigrations.makeMigrator().migrate(dbQueue)
        case .importedSnapshot:
            let migrator = OrionMigrations.makeMigrator(eraseOnSchemaChange: false)
            let unknown = try dbQueue.read { db in
                try migrator.appliedIdentifiers(db).subtracting(migrator.migrations)
            }
            guard unknown.isEmpty else {
                throw OpenError.newerSchema(path: path, unknownMigrations: unknown.sorted())
            }
            try migrator.migrate(dbQueue)
        }
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
