import Foundation
import GRDB
import EngramCoreRead

public final class EngramDatabaseWriter {
    private let pool: DatabasePool

    public init(path: String) throws {
        pool = try DatabasePool(
            path: path,
            configuration: SQLiteConnectionPolicy.writerConfiguration()
        )
    }

    public func write<T>(_ block: (GRDB.Database) throws -> T) throws -> T {
        try pool.write(block)
    }

    public func read<T>(_ block: (GRDB.Database) throws -> T) throws -> T {
        try pool.read(block)
    }

    public func checkpointPassive() throws {
        try pool.write { db in
            _ = try Row.fetchAll(db, sql: "PRAGMA wal_checkpoint(PASSIVE)")
        }
    }

    public func migrate() throws {
        try pool.write { db in
            try EngramMigrationRunner.migrate(db)
        }
    }
}
