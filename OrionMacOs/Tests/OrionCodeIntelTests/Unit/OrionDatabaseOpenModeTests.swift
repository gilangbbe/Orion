import GRDB
import XCTest

@testable import OrionCore

/// Docs/19 M1: how a database synced to the iOS companion is opened. It can't be rebuilt on the
/// device, so it's never erased, and one from a newer Orion is refused rather than half-migrated.
final class OrionDatabaseOpenModeTests: XCTestCase {
    func testImportedSnapshotMigratorNeverErases() {
        XCTAssertFalse(OrionMigrations.makeMigrator(eraseOnSchemaChange: false).eraseDatabaseOnSchemaChange)
    }

    func testAnOlderSnapshotIsMigratedUp() throws {
        let dir = try TempDir()
        let path = dir.path("snapshot.db")
        let old = try DatabaseQueue(path: path)
        try OrionMigrations.makeMigrator().migrate(old, upTo: "v3_phase3_schema")
        try old.close()

        let db = try OrionDatabase(path: path, mode: .importedSnapshot)
        let applied = try db.dbQueue.read { try OrionMigrations.makeMigrator().appliedIdentifiers($0) }
        XCTAssertEqual(applied, Set(OrionMigrations.makeMigrator().migrations))
    }

    func testASnapshotFromANewerOrionIsRefused() throws {
        let dir = try TempDir()
        let path = dir.path("snapshot.db")
        _ = try OrionDatabase(path: path)
        let queue = try DatabaseQueue(path: path)
        try queue.write { try $0.execute(sql: "INSERT INTO grdb_migrations (identifier) VALUES ('v99_future_schema')") }
        try queue.close()

        XCTAssertThrowsError(try OrionDatabase(path: path, mode: .importedSnapshot)) { error in
            XCTAssertEqual(
                error as? OrionDatabase.OpenError,
                .newerSchema(path: path, unknownMigrations: ["v99_future_schema"]))
        }
    }

    func testAFreshFileOpensAsAnImportedSnapshot() throws {
        let dir = try TempDir()
        let db = try OrionDatabase(path: dir.path("new.db"), mode: .importedSnapshot)
        XCTAssertEqual(try db.dbQueue.read { try $0.tableExists("teaching_concepts") }, true)
    }
}
