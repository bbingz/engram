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

    /// Truncates the WAL file on disk. Returns `(busy, log, checkpointed)` from
    /// SQLite. May block on `busy_timeout` if a reader holds a frame; caller is
    /// responsible for tolerating failures (e.g. continuing to rely on PASSIVE).
    @discardableResult
    public func checkpointTruncate() throws -> (busy: Int64, logFrames: Int64, checkpointed: Int64) {
        try pool.write { db in
            let row = try Row.fetchOne(db, sql: "PRAGMA wal_checkpoint(TRUNCATE)")
            let busy = row?["busy"] as Int64? ?? 1
            let log = row?["log"] as Int64? ?? 0
            let chk = row?["checkpointed"] as Int64? ?? 0
            return (busy, log, chk)
        }
    }

    public func migrate() throws {
        try pool.write { db in
            try EngramMigrationRunner.migrate(db)
        }
    }
}
