// macos/EngramCoreWrite/ProjectMove/MigrationLogReaders.swift
// Concrete GRDB-backed `MigrationLogReader` / `SessionByIdReader` for Stage 4.
// Stage 3 shipped the protocol-only abstractions so Undo + Recover could be
// unit-tested with stubs; the orchestrator and MCP handlers use these to hit
// the real database.
import Foundation
import GRDB

/// GRDB-backed `MigrationLogReader`. Opens a short read transaction per
/// query via the supplied `EngramDatabaseWriter` (which holds the pool the
/// orchestrator already uses for writes). `affected_session_ids` is decoded
/// from the `detail` JSON column.
public struct GRDBMigrationLogReader: MigrationLogReader {
    private let writer: EngramDatabaseWriter

    public init(writer: EngramDatabaseWriter) {
        self.writer = writer
    }

    public func find(migrationId: String) throws -> MigrationLogRecord? {
        try writer.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: """
                SELECT id, state, old_path, new_path, started_at, finished_at,
                       error, rolled_back_of, detail
                FROM migration_log
                WHERE id = ?
                """,
                arguments: [migrationId]
            ) else { return nil }
            return MigrationLogReaderShared.decode(row: row)
        }
    }

    public func list(states: [String], since: Date?) throws -> [MigrationLogRecord] {
        try writer.read { db in
            try MigrationLogReaderShared.fetchList(db, states: states, since: since)
        }
    }
}

/// GRDB-backed `SessionByIdReader`.
public struct GRDBSessionByIdReader: SessionByIdReader {
    private let writer: EngramDatabaseWriter

    public init(writer: EngramDatabaseWriter) {
        self.writer = writer
    }

    public func session(id: String) throws -> SessionSnapshot? {
        try writer.read { db in
            try Row.fetchOne(
                db,
                sql: "SELECT id, cwd FROM sessions WHERE id = ?",
                arguments: [id]
            ).map { row in
                SessionSnapshot(id: row["id"], cwd: row["cwd"])
            }
        }
    }
}

// MARK: - shared row decoding

public enum MigrationLogReaderShared {
    /// SQLite's `datetime('now')` format — UTC seconds, space separator.
    /// Used to format a `Date` for the `since:` parameter so string comparison
    /// against `migration_log.started_at` stays well-ordered.
    public static let sqliteDatetimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        f.timeZone = TimeZone(identifier: "UTC")
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    public static func decode(row: Row) -> MigrationLogRecord {
        let detailString = row["detail"] as String?
        let affectedSessionIds = parseAffectedSessionIds(detailString)
        return MigrationLogRecord(
            id: row["id"],
            state: row["state"],
            oldPath: row["old_path"],
            newPath: row["new_path"],
            startedAt: row["started_at"],
            finishedAt: row["finished_at"],
            error: row["error"],
            rolledBackOf: row["rolled_back_of"],
            affectedSessionIds: affectedSessionIds
        )
    }

    public static func fetchList(_ db: GRDB.Database, states: [String], since: Date?) throws -> [MigrationLogRecord] {
        var conditions: [String] = []
        var args: [DatabaseValueConvertible] = []
        if !states.isEmpty {
            let placeholders = Array(repeating: "?", count: states.count).joined(separator: ",")
            conditions.append("state IN (\(placeholders))")
            args.append(contentsOf: states.map { $0 as DatabaseValueConvertible })
        }
        if let since {
            conditions.append("started_at >= ?")
            args.append(sqliteDatetimeFormatter.string(from: since))
        }
        let whereClause = conditions.isEmpty ? "" : "WHERE " + conditions.joined(separator: " AND ")
        let sql = """
        SELECT id, state, old_path, new_path, started_at, finished_at,
               error, rolled_back_of, detail
        FROM migration_log
        \(whereClause)
        ORDER BY started_at DESC, rowid DESC
        """
        let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args))
        return rows.map(decode(row:))
    }

    /// Extracts `affectedSessionIds` from the `detail` JSON. Tolerates absent
    /// detail, malformed JSON, or missing key — returns `[]` (matches Stage 3
    /// record's empty-array contract).
    public static func parseAffectedSessionIds(_ detailString: String?) -> [String] {
        guard let detailString,
              let data = detailString.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [] }
        return (parsed["affectedSessionIds"] as? [String]) ?? []
    }
}
