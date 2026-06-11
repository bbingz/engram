import Foundation
import GRDB
import EngramCoreRead

public final class EngramDatabaseWriter: Sendable {
    private let pool: DatabasePool
    private let path: String

    public init(path: String) throws {
        self.path = path
        pool = try DatabasePool(
            path: path,
            configuration: Self.writerConfiguration()
        )
        try SQLiteFileSecurity.secureDatabaseFiles(at: path)
    }

    public func write<T>(_ block: (GRDB.Database) throws -> T) throws -> T {
        try pool.write(block)
    }

    public func writeWithoutTransaction<T>(_ block: (GRDB.Database) throws -> T) throws -> T {
        try pool.writeWithoutTransaction(block)
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
        try SQLiteFileSecurity.secureDatabaseFiles(at: path)
    }

    private static func writerConfiguration() -> Configuration {
        var configuration = Configuration()
        configuration.prepareDatabase { db in
            try db.execute(sql: "PRAGMA journal_mode = WAL")
            try applyCommonPragmas(db)
            let journalMode = (try String.fetchOne(db, sql: "PRAGMA journal_mode") ?? "").lowercased()
            guard journalMode == "wal" else {
                throw SQLiteConnectionPolicyError.journalModeNotWAL(journalMode)
            }
        }
        return configuration
    }

    private static func applyCommonPragmas(_ db: GRDB.Database) throws {
        try db.execute(sql: "PRAGMA busy_timeout = \(SQLiteConnectionPolicy.busyTimeoutMilliseconds)")
        try db.execute(sql: "PRAGMA foreign_keys = ON")
        try db.execute(sql: "PRAGMA synchronous = NORMAL")
        try db.execute(sql: "PRAGMA wal_autocheckpoint = \(SQLiteConnectionPolicy.walAutocheckpointPages)")
        try db.execute(sql: "PRAGMA cache_size = -\(SQLiteConnectionPolicy.cacheSizeKiB)")
        let timeout = try Int.fetchOne(db, sql: "PRAGMA busy_timeout") ?? 0
        guard timeout >= SQLiteConnectionPolicy.minimumBusyTimeoutMilliseconds else {
            throw SQLiteConnectionPolicyError.busyTimeoutTooLow(timeout)
        }
    }
}
