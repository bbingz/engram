import Foundation
import GRDB

public struct StartupUsageSnapshot: Equatable, Sendable {
    public let source: String
    public let metric: String
    public let value: Double
    public let unit: String?
    public let resetAt: String?
    public let limit: Double?
    public let status: String?

    public init(
        source: String,
        metric: String,
        value: Double,
        unit: String? = "%",
        resetAt: String? = nil,
        limit: Double? = nil,
        status: String? = nil
    ) {
        self.source = source
        self.metric = metric
        self.value = value
        self.unit = unit
        self.resetAt = resetAt
        self.limit = limit
        self.status = status
    }
}

public struct StartupUsageTokenLimits: Equatable, Sendable {
    public let fiveHourTokens: Double?
    public let weeklyTokens: Double?

    public init(fiveHourTokens: Double? = nil, weeklyTokens: Double? = nil) {
        self.fiveHourTokens = fiveHourTokens
        self.weeklyTokens = weeklyTokens
    }
}

public final class WriterStartupUsageCollector: StartupUsageCollecting {
    private static let managedMetrics = [
        "5h token pressure",
        "5h token share",
        "5h token total",
        "7d cost share",
        "weekly token pressure",
        "7d token share",
        "7d token total"
    ]

    private let writer: EngramDatabaseWriter
    private let now: () -> Date
    private let tokenLimits: [String: StartupUsageTokenLimits]
    private let emit: ([StartupUsageSnapshot]) -> Void

    public init(
        writer: EngramDatabaseWriter,
        now: @escaping () -> Date = Date.init,
        tokenLimits: [String: StartupUsageTokenLimits] = [:],
        emit: @escaping ([StartupUsageSnapshot]) -> Void = { _ in }
    ) {
        self.writer = writer
        self.now = now
        self.tokenLimits = Dictionary(
            tokenLimits.compactMap { source, limits in
                let normalizedSource = Self.normalizedSourceKey(source)
                return normalizedSource.isEmpty ? nil : (normalizedSource, limits)
            },
            uniquingKeysWith: { _, latest in latest }
        )
        self.emit = emit
    }

    private static func normalizedSourceKey(_ source: String) -> String {
        source.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    public func start() {
        guard let snapshots = try? collect(), !snapshots.isEmpty else { return }
        emit(snapshots)
    }

    @discardableResult
    public func collect() throws -> [StartupUsageSnapshot] {
        let timestamp = isoString(now())
        let sinceSevenDays = isoString(now().addingTimeInterval(-7 * 24 * 60 * 60))
        let sinceFiveHours = isoString(now().addingTimeInterval(-5 * 60 * 60))

        return try writer.write { db in
            var snapshots: [StartupUsageSnapshot] = []
            let sevenDayRows = try usageAggregates(db, since: sinceSevenDays)
            let fiveHourRows = try usageAggregates(db, since: sinceFiveHours)
            try clearManagedSnapshots(db)
            try appendShareSnapshots(
                metric: "7d cost share",
                rows: sevenDayRows.map {
                    ($0.source, $0.cost, resetAt($0.earliestStartTime, adding: 7 * 24 * 60 * 60))
                },
                timestamp: timestamp,
                db: db,
                snapshots: &snapshots
            )
            try appendShareSnapshots(
                metric: "7d token share",
                rows: sevenDayRows.map {
                    ($0.source, Double($0.tokens), resetAt($0.earliestStartTime, adding: 7 * 24 * 60 * 60))
                },
                timestamp: timestamp,
                db: db,
                snapshots: &snapshots
            )
            try appendShareSnapshots(
                metric: "5h token share",
                rows: fiveHourRows.map {
                    ($0.source, Double($0.tokens), resetAt($0.earliestStartTime, adding: 5 * 60 * 60))
                },
                timestamp: timestamp,
                db: db,
                snapshots: &snapshots
            )
            try appendTokenPressureSnapshots(
                metric: "weekly token pressure",
                rows: sevenDayRows.map {
                    ($0.source, Double($0.tokens), resetAt($0.earliestStartTime, adding: 7 * 24 * 60 * 60))
                },
                limit: { tokenLimits[$0]?.weeklyTokens },
                timestamp: timestamp,
                db: db,
                snapshots: &snapshots
            )
            try appendTokenPressureSnapshots(
                metric: "5h token pressure",
                rows: fiveHourRows.map {
                    ($0.source, Double($0.tokens), resetAt($0.earliestStartTime, adding: 5 * 60 * 60))
                },
                limit: { tokenLimits[$0]?.fiveHourTokens },
                timestamp: timestamp,
                db: db,
                snapshots: &snapshots
            )
            try appendValueSnapshots(
                metric: "7d token total",
                unit: "tokens",
                rows: sevenDayRows.map {
                    ($0.source, Double($0.tokens), resetAt($0.earliestStartTime, adding: 7 * 24 * 60 * 60))
                },
                timestamp: timestamp,
                db: db,
                snapshots: &snapshots
            )
            try appendValueSnapshots(
                metric: "5h token total",
                unit: "tokens",
                rows: fiveHourRows.map {
                    ($0.source, Double($0.tokens), resetAt($0.earliestStartTime, adding: 5 * 60 * 60))
                },
                timestamp: timestamp,
                db: db,
                snapshots: &snapshots
            )
            return snapshots
        }
    }

    private func clearManagedSnapshots(_ db: Database) throws {
        let placeholders = Array(repeating: "?", count: Self.managedMetrics.count).joined(separator: ", ")
        try db.execute(
            sql: "DELETE FROM usage_snapshots WHERE metric IN (\(placeholders))",
            arguments: StatementArguments(Self.managedMetrics)
        )
    }

    private struct UsageAggregate {
        var source: String
        var cost: Double
        var tokens: Int
        var earliestStartTime: String?
    }

    private func usageAggregates(_ db: Database, since: String) throws -> [UsageAggregate] {
        var arguments = StatementArguments()
        arguments += [since, since, since]
        let rows = try Row.fetchAll(
            db,
            sql: """
            SELECT LOWER(TRIM(s.source)) AS source,
                   MIN(CASE WHEN s.start_time < ? THEN ? ELSE s.start_time END) AS earliest_start_time,
                   SUM(c.cost_usd) AS cost_usd,
                   SUM(
                     COALESCE(c.input_tokens, 0)
                     + COALESCE(c.output_tokens, 0)
                     + COALESCE(c.cache_read_tokens, 0)
                     + COALESCE(c.cache_creation_tokens, 0)
                   ) AS tokens
            FROM session_costs c
            JOIN sessions s ON s.id = c.session_id
            WHERE COALESCE(NULLIF(s.end_time, ''), NULLIF(s.indexed_at, ''), s.start_time) >= ?
              AND s.hidden_at IS NULL
              AND TRIM(s.source) <> ''
            GROUP BY LOWER(TRIM(s.source))
            HAVING SUM(c.cost_usd) > 0 OR SUM(
              COALESCE(c.input_tokens, 0)
              + COALESCE(c.output_tokens, 0)
              + COALESCE(c.cache_read_tokens, 0)
              + COALESCE(c.cache_creation_tokens, 0)
            ) > 0
            ORDER BY LOWER(TRIM(s.source))
            """,
            arguments: arguments
        )
        return rows.compactMap { row in
            let source: String = row["source"]
            return UsageAggregate(
                source: source,
                cost: (row["cost_usd"] as Double?) ?? 0,
                tokens: (row["tokens"] as Int?) ?? 0,
                earliestStartTime: row["earliest_start_time"] as String?
            )
        }
    }

    private func appendShareSnapshots(
        metric: String,
        rows: [(source: String, value: Double, resetAt: String?)],
        timestamp: String,
        db: Database,
        snapshots: inout [StartupUsageSnapshot]
    ) throws {
        let total = rows.reduce(0.0) { $0 + $1.value }
        guard total > 0 else { return }
        for row in rows where row.value > 0 {
            let share = ((max(0, min(100, (row.value / total) * 100)) * 10).rounded() / 10)
            try db.execute(
                sql: """
                INSERT INTO usage_snapshots(source, metric, value, unit, reset_at, limit_value, status, collected_at)
                VALUES (?, ?, ?, '%', ?, NULL, 'observed', ?)
                """,
                arguments: [row.source, metric, share, row.resetAt, timestamp]
            )
            snapshots.append(
                StartupUsageSnapshot(
                    source: row.source,
                    metric: metric,
                    value: share,
                    unit: "%",
                    resetAt: row.resetAt,
                    status: "observed"
                )
            )
        }
    }

    private func appendValueSnapshots(
        metric: String,
        unit: String,
        rows: [(source: String, value: Double, resetAt: String?)],
        timestamp: String,
        db: Database,
        snapshots: inout [StartupUsageSnapshot]
    ) throws {
        for row in rows where row.value > 0 {
            try db.execute(
                sql: """
                INSERT INTO usage_snapshots(source, metric, value, unit, reset_at, limit_value, status, collected_at)
                VALUES (?, ?, ?, ?, ?, NULL, 'observed', ?)
                """,
                arguments: [row.source, metric, row.value, unit, row.resetAt, timestamp]
            )
            snapshots.append(
                StartupUsageSnapshot(
                    source: row.source,
                    metric: metric,
                    value: row.value,
                    unit: unit,
                    resetAt: row.resetAt,
                    status: "observed"
                )
            )
        }
    }

    private func appendTokenPressureSnapshots(
        metric: String,
        rows: [(source: String, value: Double, resetAt: String?)],
        limit: (String) -> Double?,
        timestamp: String,
        db: Database,
        snapshots: inout [StartupUsageSnapshot]
    ) throws {
        for row in rows where row.value > 0 {
            guard let tokenLimit = limit(row.source), tokenLimit.isFinite, tokenLimit > 0 else {
                continue
            }
            let pressure = (((row.value / tokenLimit) * 100) * 10).rounded() / 10
            let status = pressureStatus(pressure)
            try db.execute(
                sql: """
                INSERT INTO usage_snapshots(source, metric, value, unit, reset_at, limit_value, status, collected_at)
                VALUES (?, ?, ?, '%', ?, 100.0, ?, ?)
                """,
                arguments: [row.source, metric, pressure, row.resetAt, status, timestamp]
            )
            snapshots.append(
                StartupUsageSnapshot(
                    source: row.source,
                    metric: metric,
                    value: pressure,
                    unit: "%",
                    resetAt: row.resetAt,
                    limit: 100.0,
                    status: status
                )
            )
        }
    }

    private func resetAt(_ startTime: String?, adding interval: TimeInterval) -> String? {
        guard let startTime, let startDate = parseISODate(startTime) else {
            return nil
        }
        return isoString(startDate.addingTimeInterval(interval))
    }

    private func parseISODate(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) {
            return date
        }

        let wholeSeconds = ISO8601DateFormatter()
        wholeSeconds.formatOptions = [.withInternetDateTime]
        return wholeSeconds.date(from: value)
    }

    private func isoString(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private func pressureStatus(_ value: Double) -> String {
        if value >= 90 {
            return "critical"
        }
        if value >= 75 {
            return "attention"
        }
        return "ok"
    }
}
