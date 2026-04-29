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
        let timeout = try Int.fetchOne(db, sql: "PRAGMA busy_timeout") ?? 0
        guard timeout >= minimumBusyTimeoutMilliseconds else {
            throw SQLiteConnectionPolicyError.busyTimeoutTooLow(timeout)
        }
    }
}
