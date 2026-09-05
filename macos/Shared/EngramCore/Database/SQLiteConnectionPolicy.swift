import Darwin
import Foundation
import GRDB

public enum SQLiteConnectionPolicyError: Error, Equatable {
    case journalModeNotWAL(String)
    case busyTimeoutTooLow(Int)
    case fileSecurityOwnerMismatch(String)
    case fileSecurityModeMismatch(String, Int)
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
    /// hot-page residency benefit without that risk. Shared with the app read
    /// pool (`DatabaseManager.openReadOnlyPool`) via `SharedDBConfig` so the two
    /// cannot drift.
    public static let cacheSizeKiB = SharedDBConfig.cacheSizeKiB

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

    public static func readerConfiguration(
        busyTimeoutMilliseconds timeoutMilliseconds: Int = busyTimeoutMilliseconds
    ) -> Configuration {
        var configuration = Configuration()
        configuration.readonly = true
        configuration.prepareDatabase { db in
            // docs/invariants.md #1: reader configuration must not execute
            // writer-only PRAGMAs that create or modify WAL sidecars.
            try applyReaderPragmas(db, busyTimeoutMilliseconds: timeoutMilliseconds)
            let timeout = try Int.fetchOne(db, sql: "PRAGMA busy_timeout") ?? 0
            guard timeoutMilliseconds == 0 || timeout >= minimumBusyTimeoutMilliseconds else {
                throw SQLiteConnectionPolicyError.busyTimeoutTooLow(timeout)
            }
            let journalMode = (try String.fetchOne(db, sql: "PRAGMA journal_mode") ?? "").lowercased()
            guard journalMode == "wal" else {
                throw SQLiteConnectionPolicyError.journalModeNotWAL(journalMode)
            }
        }
        return configuration
    }

    /// Availability and semantic readers must fail closed instead of occupying
    /// a request for the normal reader's 30-second lock wait.
    public static func immediateReaderConfiguration() -> Configuration {
        var configuration = Configuration()
        configuration.readonly = true
        configuration.busyMode = .immediateError
        configuration.prepareDatabase { db in
            // docs/invariants.md #1: this remains a read-only connection and
            // must not execute writer-only PRAGMAs or create WAL sidecars.
            try applyReaderPragmas(db, busyTimeoutMilliseconds: 0)
            let journalMode = (try String.fetchOne(db, sql: "PRAGMA journal_mode") ?? "").lowercased()
            guard journalMode == "wal" else {
                throw SQLiteConnectionPolicyError.journalModeNotWAL(journalMode)
            }
        }
        return configuration
    }

    public static func applyCommonPragmas(_ db: GRDB.Database) throws {
        try applyReaderPragmas(db)
        try db.execute(sql: "PRAGMA synchronous = NORMAL")
        try db.execute(sql: "PRAGMA wal_autocheckpoint = \(walAutocheckpointPages)")
    }

    private static func applyReaderPragmas(
        _ db: GRDB.Database,
        busyTimeoutMilliseconds timeoutMilliseconds: Int = busyTimeoutMilliseconds
    ) throws {
        try db.execute(sql: "PRAGMA busy_timeout = \(timeoutMilliseconds)")
        try db.execute(sql: "PRAGMA foreign_keys = ON")
        try db.execute(sql: "PRAGMA cache_size = -\(cacheSizeKiB)")
        let timeout = try Int.fetchOne(db, sql: "PRAGMA busy_timeout") ?? 0
        guard timeoutMilliseconds == 0 || timeout >= minimumBusyTimeoutMilliseconds else {
            throw SQLiteConnectionPolicyError.busyTimeoutTooLow(timeout)
        }
    }
}

public enum FileSystemPathIdentity {
    /// Resolve the longest existing prefix so equivalent macOS spellings such
    /// as `/tmp/x` and `/private/tmp/x` compare consistently even when `x`
    /// has not been created yet.
    public static func realpathPath(_ path: String) -> String {
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        var existingPrefix = standardized
        var missingSuffix: [String] = []

        while true {
            if let resolved = Darwin.realpath(existingPrefix, nil) {
                defer { free(resolved) }
                return missingSuffix.reduce(URL(fileURLWithPath: String(cString: resolved))) { url, component in
                    url.appendingPathComponent(component)
                }.standardizedFileURL.path
            }
            let prefixURL = URL(fileURLWithPath: existingPrefix).standardizedFileURL
            let parent = prefixURL.deletingLastPathComponent().path
            guard parent != existingPrefix else { return standardized }
            missingSuffix.insert(prefixURL.lastPathComponent, at: 0)
            existingPrefix = parent
        }
    }
}

public enum SQLiteFileSecurity {
    public static func secureDatabaseFiles(at path: String) throws {
        guard path != ":memory:" else { return }
        let fileManager = FileManager.default
        for candidate in [path, "\(path)-wal", "\(path)-shm"] where fileManager.fileExists(atPath: candidate) {
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: candidate)
            var info = stat()
            guard lstat(candidate, &info) == 0 else {
                throw CocoaError(.fileReadNoSuchFile)
            }
            guard info.st_uid == geteuid() else {
                throw SQLiteConnectionPolicyError.fileSecurityOwnerMismatch(candidate)
            }
            let mode = Int(info.st_mode & 0o777)
            guard mode == 0o600 else {
                throw SQLiteConnectionPolicyError.fileSecurityModeMismatch(candidate, mode)
            }
        }
    }
}
