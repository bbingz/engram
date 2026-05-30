import Foundation
import GRDB

public enum SQLiteConnectionPolicyError: Error, Equatable {
    case journalModeNotWAL(String)
    case busyTimeoutTooLow(Int)
}

public enum SQLiteConnectionPolicy {
    public static let busyTimeoutMilliseconds = 30_000
    public static let minimumBusyTimeoutMilliseconds = 5_000
    public static let walAutocheckpointPages = 1_000
    /// Page cache per connection. Negative = KiB (not pages), so ~16 MiB
    /// regardless of page size — larger than the default ~2 MiB to keep hot FTS
    /// b-tree pages resident across queries. This is the primary read accelerator
    /// for the hundreds-of-MB FTS-heavy index DB.
    ///
    /// We deliberately do NOT enable `PRAGMA mmap_size`. The service runs an
    /// in-process startup `VACUUM` (StartupBackfills.vacuumIfNeeded) that rewrites
    /// and can shrink the DB file while reader connections in the SAME process are
    /// already serving socket requests; a large mmap window over a file truncated
    /// underneath a live reader is a SIGBUS hazard. cache_size delivers the
    /// hot-page residency benefit without that risk.
    public static let cacheSizeKiB = 16_000

    public static func writerConfiguration() -> Configuration {
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

    public static func readerConfiguration() -> Configuration {
        var configuration = Configuration()
        configuration.readonly = true
        configuration.prepareDatabase { db in
            try applyCommonPragmas(db)
            let timeout = try Int.fetchOne(db, sql: "PRAGMA busy_timeout") ?? 0
            guard timeout >= minimumBusyTimeoutMilliseconds else {
                throw SQLiteConnectionPolicyError.busyTimeoutTooLow(timeout)
            }
            let journalMode = (try String.fetchOne(db, sql: "PRAGMA journal_mode") ?? "").lowercased()
            guard journalMode == "wal" else {
                throw SQLiteConnectionPolicyError.journalModeNotWAL(journalMode)
            }
        }
        return configuration
    }

    public static func applyCommonPragmas(_ db: GRDB.Database) throws {
        try db.execute(sql: "PRAGMA busy_timeout = \(busyTimeoutMilliseconds)")
        try db.execute(sql: "PRAGMA foreign_keys = ON")
        try db.execute(sql: "PRAGMA synchronous = NORMAL")
        try db.execute(sql: "PRAGMA wal_autocheckpoint = \(walAutocheckpointPages)")
        try db.execute(sql: "PRAGMA cache_size = -\(cacheSizeKiB)")
        let timeout = try Int.fetchOne(db, sql: "PRAGMA busy_timeout") ?? 0
        guard timeout >= minimumBusyTimeoutMilliseconds else {
            throw SQLiteConnectionPolicyError.busyTimeoutTooLow(timeout)
        }
    }
}

public enum SQLiteFileSecurity {
    public static func secureDatabaseFiles(at path: String) throws {
        guard path != ":memory:" else { return }
        let fileManager = FileManager.default
        for candidate in [path, "\(path)-wal", "\(path)-shm"] where fileManager.fileExists(atPath: candidate) {
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: candidate)
        }
    }
}
