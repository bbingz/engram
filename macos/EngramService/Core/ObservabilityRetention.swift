import Foundation
import GRDB

/// Prunes the observability tables (metrics / traces / ai_audit_log / logs) to
/// bounded age windows. These tables grew unbounded — on the live DB `metrics`
/// alone was ~56 MB / 661k rows, all stale (the writer stopped 2026-04-24) —
/// and nothing in the product ever pruned them.
///
/// Timestamps are stored as ISO8601 TEXT. ISO8601 strings sort lexically in
/// chronological order, so `column < cutoffString` is a correct age filter.
/// This was verified against a copy of the live DB across the three formats the
/// tables actually store: `…Z`, `…` (no Z, ai_audit_log), and millisecond
/// fractions — all compare correctly against the formatter's default output.
enum ObservabilityRetention {
    struct Config {
        var metricsDays = 30
        var tracesDays = 14
        var auditDays = 30
        var logsDays = 14
        init() {}
    }

    /// Prune within a caller-supplied write transaction (the service's single
    /// writer). Deletes at most `limit` aged rows PER TABLE this call and returns
    /// the number deleted, so the runtime can loop (each iteration its own gated
    /// transaction) and bound the WAL spike + writer-gate hold on the one-time
    /// 661k-row backlog. The default unbounded limit deletes everything in one
    /// pass (used by tests). Table/column names are fixed literals; only the
    /// cutoff and limit are bound. The rowid sub-select keeps the bounded delete
    /// portable (no SQLITE_ENABLE_UPDATE_DELETE_LIMIT dependency).
    @discardableResult
    static func prune(
        _ db: Database,
        limit: Int = Int.max,
        now: Date = Date(),
        config: Config = Config()
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
        return total
    }
}
