import Foundation
import GRDB

/// Retention windows for product tables that still receive append-only rows.
public struct ObservabilityRetentionConfig: Sendable {
    public var auditDays = 30
    // usage_snapshots gets a fresh row-set appended every service start with
    // no dedup/upsert (StartupUsageCollector), so without retention it grows
    // unbounded like ai_audit_log. Keep a longer window since the rows
    // are tiny and the Usage page reads only the latest per source.
    public var usageSnapshotsDays = 90

    public init() {}
}

/// Prunes append-only runtime tables to bounded age windows.
///
/// Timestamps are stored as ISO8601 TEXT. ISO8601 strings sort lexically in
/// chronological order, so `column < cutoffString` is a correct age filter.
enum ObservabilityRetention {
    /// Prune within a caller-supplied write transaction. Deletes at most `limit`
    /// aged rows PER TABLE this call and returns the number deleted, so the
    /// runtime can loop with bounded WAL growth and writer-gate hold time.
    @discardableResult
    static func prune(
        _ db: Database,
        limit: Int = Int.max,
        now: Date = Date(),
        config: ObservabilityRetentionConfig = ObservabilityRetentionConfig()
    ) throws -> Int {
        let formatter = ISO8601DateFormatter()
        func cutoff(_ days: Int) -> String {
            formatter.string(from: now.addingTimeInterval(-Double(days) * 86_400))
        }
        func delete(_ table: String, _ column: String, _ days: Int) throws -> Int {
            guard try tableExists(db, table) else { return 0 }
            try db.execute(
                sql: """
                DELETE FROM \(table) WHERE rowid IN (
                    SELECT rowid FROM \(table) WHERE \(column) < ? LIMIT ?
                )
                """,
                arguments: [cutoff(days), limit]
            )
            return db.changesCount
        }
        var total = 0
        total += try delete("ai_audit_log", "ts", config.auditDays)
        total += try delete("usage_snapshots", "collected_at", config.usageSnapshotsDays)
        return total
    }

    private static func tableExists(_ db: Database, _ table: String) throws -> Bool {
        try Bool.fetchOne(
            db,
            sql: "SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE type IN ('table', 'view') AND name = ?)",
            arguments: [table]
        ) ?? false
    }
}

public extension EngramDatabaseWriter {
    /// Runs observability retention inside EngramCoreWrite so the GRDB Database
    /// handle is used by the same framework that owns the DatabasePool.
    @discardableResult
    func pruneObservabilityRetention(
        limit: Int = Int.max,
        now: Date = Date(),
        config: ObservabilityRetentionConfig = ObservabilityRetentionConfig()
    ) throws -> Int {
        try write { db in
            try ObservabilityRetention.prune(db, limit: limit, now: now, config: config)
        }
    }
}
