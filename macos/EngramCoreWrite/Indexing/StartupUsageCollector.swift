import Foundation
import GRDB

public struct StartupUsageSnapshot: Equatable, Sendable {
    public let source: String
    public let metric: String
    public let value: Double
    public let resetAt: String?
    public let status: String?

    public init(source: String, metric: String, value: Double, resetAt: String? = nil, status: String? = nil) {
        self.source = source
        self.metric = metric
        self.value = value
        self.resetAt = resetAt
        self.status = status
    }
}

public final class WriterStartupUsageCollector: StartupUsageCollecting {
    private static let trackedSources = ["claude-code", "codex", "gemini-cli", "antigravity", "opencode"]

    private let writer: EngramDatabaseWriter
    private let now: () -> Date
    private let emit: ([StartupUsageSnapshot]) -> Void

    public init(
        writer: EngramDatabaseWriter,
        now: @escaping () -> Date = Date.init,
        emit: @escaping ([StartupUsageSnapshot]) -> Void = { _ in }
    ) {
        self.writer = writer
        self.now = now
        self.emit = emit
    }

    public func start() {
        guard let snapshots = try? collect(), !snapshots.isEmpty else { return }
        emit(snapshots)
    }

    @discardableResult
    public func collect() throws -> [StartupUsageSnapshot] {
        let timestamp = isoString(now())
        let since = isoString(now().addingTimeInterval(-7 * 24 * 60 * 60))

        return try writer.write { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT s.source AS source,
                       SUM(c.cost_usd) AS cost_usd
                FROM session_costs c
                JOIN sessions s ON s.id = c.session_id
                WHERE s.start_time >= ?
                  AND s.source IN ('claude-code', 'codex', 'gemini-cli', 'antigravity', 'opencode')
                  AND s.hidden_at IS NULL
                GROUP BY s.source
                HAVING SUM(c.cost_usd) > 0
                ORDER BY s.source
                """,
                arguments: [since]
            )
            let total = rows.reduce(0.0) { partial, row in
                partial + ((row["cost_usd"] as Double?) ?? 0)
            }
            guard total > 0 else { return [] }

            var snapshots: [StartupUsageSnapshot] = []
            for row in rows {
                let source: String = row["source"]
                guard Self.trackedSources.contains(source) else { continue }
                let cost = (row["cost_usd"] as Double?) ?? 0
                let share = max(0, min(100, (cost / total) * 100))
                try db.execute(
                    sql: """
                    INSERT INTO usage_snapshots(source, metric, value, unit, reset_at, collected_at)
                    VALUES (?, '7d cost share', ?, '%', NULL, ?)
                    """,
                    arguments: [source, share, timestamp]
                )
                snapshots.append(
                    StartupUsageSnapshot(
                        source: source,
                        metric: "7d cost share",
                        value: (share * 10).rounded() / 10,
                        status: "observed"
                    )
                )
            }
            return snapshots
        }
    }

    private func isoString(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}
