import Foundation
import GRDB

/// Retention windows for legacy observability tables.
public struct ObservabilityRetentionConfig: Sendable {
    public var metricsDays = 30
    public var tracesDays = 14
    public var auditDays = 30
    public var logsDays = 14
    // usage_snapshots gets a fresh row-set appended every service start with
    // no dedup/upsert (StartupUsageCollector), so without retention it grows
    // unbounded like the tables above. Keep a longer window since the rows
    // are tiny and the Usage page reads only the latest per source.
    public var usageSnapshotsDays = 90

    public init() {}
}

/// Prunes the observability tables (metrics / traces / ai_audit_log / logs) to
/// bounded age windows. These tables grew unbounded, and nothing in the product
/// previously pruned them.
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
        total += try delete("metrics", "ts", config.metricsDays)
        total += try delete("traces", "start_ts", config.tracesDays)
        total += try delete("ai_audit_log", "ts", config.auditDays)
        total += try delete("logs", "ts", config.logsDays)
        total += try delete("usage_snapshots", "collected_at", config.usageSnapshotsDays)
        return total
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
