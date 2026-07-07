import XCTest
import GRDB
import Foundation
@testable import EngramServiceCore

final class EngramServiceCostsTests: XCTestCase {
    func testCostsAggregatesPerSourcePerDayAndTotals() async throws {
        let path = try seedCostsFixture { db in
            try insertSession(db, id: "a", source: "codex", startTime: "2026-06-01T10:00:00Z")
            try insertSession(db, id: "b", source: "codex", startTime: "2026-06-02T10:00:00Z")
            try insertSession(db, id: "c", source: "claude-code", startTime: "2026-06-02T11:00:00Z")
            try insertCost(db, sessionId: "a", costUsd: 1.25)
            try insertCost(db, sessionId: "b", costUsd: 0.75)
            try insertCost(db, sessionId: "c", costUsd: 2.0)
        }

        let provider = try SQLiteEngramServiceReadProvider(databasePath: path)
        let costs = try await provider.costs()

        XCTAssertEqual(costs.totalUsd, 4.0, accuracy: 0.001)

        let codex = try XCTUnwrap(costs.perSource.first(where: { $0.key == "codex" }))
        XCTAssertEqual(codex.costUsd, 2.0, accuracy: 0.001)
        XCTAssertEqual(codex.sessionCount, 2)
        let claude = try XCTUnwrap(costs.perSource.first(where: { $0.key == "claude-code" }))
        XCTAssertEqual(claude.costUsd, 2.0, accuracy: 0.001)
        XCTAssertEqual(claude.sessionCount, 1)

        // Per-day only includes the last 30 days; the fixture seeds dates that
        // may be outside that window depending on the current date, so assert
        // structure (one row per distinct seeded day that falls in range) and
        // that day rows carry the source-summed cost shape, not the exact dates.
        let dayKeys = Set(costs.perDay.map(\.day))
        for day in costs.perDay {
            XCTAssertGreaterThanOrEqual(day.costUsd, 0)
        }
        XCTAssertLessThanOrEqual(dayKeys.count, 2)
    }

    func testCostsAggregatesPerDayWithinWindow() async throws {
        // Buckets are keyed by LOCAL day, so derive the expected keys from the
        // seeded instants through the same local conversion (mid-day instants
        // keep them off the midnight boundary in any practical timezone).
        let todayInstant = Calendar.current.date(
            bySettingHour: 12, minute: 0, second: 0, of: Date()
        ) ?? Date()
        let yesterdayInstant = todayInstant.addingTimeInterval(-86_400)
        let today = localDay(todayInstant)
        let yesterday = localDay(yesterdayInstant)
        let path = try seedCostsFixture { db in
            try insertSession(db, id: "t1", source: "codex", startTime: isoInstant(todayInstant))
            try insertSession(db, id: "t2", source: "codex", startTime: isoInstant(todayInstant.addingTimeInterval(3_600)))
            try insertSession(db, id: "y1", source: "codex", startTime: isoInstant(yesterdayInstant))
            try insertCost(db, sessionId: "t1", costUsd: 1.0)
            try insertCost(db, sessionId: "t2", costUsd: 0.5)
            try insertCost(db, sessionId: "y1", costUsd: 2.0)
        }

        let provider = try SQLiteEngramServiceReadProvider(databasePath: path)
        let costs = try await provider.costs()

        XCTAssertEqual(costs.todayUsd, 1.5, accuracy: 0.001)
        let todayRow = try XCTUnwrap(costs.perDay.first(where: { $0.day == today }))
        XCTAssertEqual(todayRow.costUsd, 1.5, accuracy: 0.001)
        let yesterdayRow = try XCTUnwrap(costs.perDay.first(where: { $0.day == yesterday }))
        XCTAssertEqual(yesterdayRow.costUsd, 2.0, accuracy: 0.001)
        XCTAssertEqual(costs.totalUsd, 3.5, accuracy: 0.001)
    }

    func testCostsBucketsByLocalDayNotUTC() async throws {
        // A session whose UTC instant is "now" must land in today's LOCAL bucket
        // and todayUsd in every timezone. Seeding the current UTC instant is
        // TZ-independent because "now" is today everywhere. The local-day key is
        // derived through the same localtime conversion the SQL uses, so a UTC
        // bucket regression (the old `date(s.start_time)`) would put the row on
        // the wrong day in zones where local and UTC days differ near midnight.
        let nowUTC = isoInstant(Date())
        let localToday = localDay(Date())
        let path = try seedCostsFixture { db in
            try insertSession(db, id: "now", source: "codex", startTime: nowUTC)
            try insertCost(db, sessionId: "now", costUsd: 3.0)
        }

        let provider = try SQLiteEngramServiceReadProvider(databasePath: path)
        let costs = try await provider.costs()

        XCTAssertEqual(costs.todayUsd, 3.0, accuracy: 0.001)
        XCTAssertEqual(costs.monthToDateUsd, 3.0, accuracy: 0.001)
        let todayRow = try XCTUnwrap(costs.perDay.first(where: { $0.day == localToday }))
        XCTAssertEqual(todayRow.costUsd, 3.0, accuracy: 0.001)
    }

    func testCostsExcludesHiddenSessions() async throws {
        let path = try seedCostsFixture { db in
            try insertSession(db, id: "visible", source: "codex", startTime: "2026-06-02T10:00:00Z")
            try insertSession(db, id: "hidden", source: "codex", startTime: "2026-06-02T11:00:00Z", hiddenAt: "2026-06-03T00:00:00Z")
            try insertCost(db, sessionId: "visible", costUsd: 1.0)
            try insertCost(db, sessionId: "hidden", costUsd: 99.0)
        }

        let provider = try SQLiteEngramServiceReadProvider(databasePath: path)
        let costs = try await provider.costs()

        XCTAssertEqual(costs.totalUsd, 1.0, accuracy: 0.001)
        XCTAssertEqual(costs.perSource.count, 1)
        XCTAssertEqual(costs.perSource.first?.sessionCount, 1)
    }

    func testCostsEmptyWhenTableAbsent() async throws {
        // Seed sessions but NOT session_costs → the tableExists guard returns an
        // all-zero response instead of throwing "no such table".
        let path = try seedCostsFixture(createCostsTable: false) { db in
            try insertSession(db, id: "a", source: "codex", startTime: "2026-06-02T10:00:00Z")
        }

        let provider = try SQLiteEngramServiceReadProvider(databasePath: path)
        let costs = try await provider.costs()

        XCTAssertEqual(costs.totalUsd, 0)
        XCTAssertTrue(costs.perSource.isEmpty)
        XCTAssertTrue(costs.perDay.isEmpty)
        XCTAssertEqual(costs.monthToDateUsd, 0)
        XCTAssertEqual(costs.todayUsd, 0)
    }

    func testCostsTreatNullCostRowsAsZero() async throws {
        let todayInstant = Calendar.current.date(
            bySettingHour: 12, minute: 0, second: 0, of: Date()
        ) ?? Date()
        let path = try seedCostsFixture { db in
            try insertSession(db, id: "priced", source: "codex", startTime: isoInstant(todayInstant))
            try insertSession(db, id: "unpriced", source: "codex", startTime: isoInstant(todayInstant.addingTimeInterval(60)))
            try insertCost(db, sessionId: "priced", costUsd: 1.25)
            try insertCost(db, sessionId: "unpriced", costUsd: nil)
        }

        let provider = try SQLiteEngramServiceReadProvider(databasePath: path)
        let costs = try await provider.costs()

        XCTAssertEqual(costs.totalUsd, 1.25, accuracy: 0.001)
        XCTAssertEqual(costs.todayUsd, 1.25, accuracy: 0.001)
        let codex = try XCTUnwrap(costs.perSource.first(where: { $0.key == "codex" }))
        XCTAssertEqual(codex.costUsd, 1.25, accuracy: 0.001)
        XCTAssertEqual(codex.sessionCount, 2)
    }

    // MARK: - Helpers

    /// Full UTC ISO instant (what adapters store in `start_time`).
    private func isoInstant(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: date)
    }

    /// Local calendar day for the given instant (matches SQLite `localtime`).
    private func localDay(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone.current
        return formatter.string(from: date)
    }

    private func seedCostsFixture(
        createCostsTable: Bool = true,
        seed: (GRDB.Database) throws -> Void
    ) throws -> String {
        let path = NSTemporaryDirectory() + "engram-costs-\(UUID().uuidString.prefix(8)).sqlite"
        var configuration = Configuration()
        configuration.prepareDatabase { db in
            try db.execute(sql: "PRAGMA journal_mode = WAL")
        }
        let queue = try DatabaseQueue(path: path, configuration: configuration)
        try queue.write { db in
            try db.execute(sql: """
                CREATE TABLE sessions (
                  id TEXT PRIMARY KEY,
                  source TEXT NOT NULL,
                  start_time TEXT NOT NULL,
                  cwd TEXT NOT NULL DEFAULT '',
                  file_path TEXT NOT NULL DEFAULT '',
                  message_count INTEGER NOT NULL DEFAULT 0,
                  size_bytes INTEGER NOT NULL DEFAULT 0,
                  indexed_at TEXT NOT NULL DEFAULT '',
                  hidden_at TEXT
                );
            """)
            if createCostsTable {
                try db.execute(sql: """
                    CREATE TABLE session_costs (
                      session_id TEXT PRIMARY KEY,
                      model TEXT,
                      input_tokens INTEGER DEFAULT 0,
                      output_tokens INTEGER DEFAULT 0,
                      cache_read_tokens INTEGER DEFAULT 0,
                      cache_creation_tokens INTEGER DEFAULT 0,
                      cost_usd REAL DEFAULT 0,
                      computed_at TEXT
                    );
                """)
            }
            try seed(db)
        }
        return path
    }

    private func insertSession(
        _ db: GRDB.Database,
        id: String,
        source: String,
        startTime: String,
        hiddenAt: String? = nil
    ) throws {
        try db.execute(
            sql: """
                INSERT INTO sessions (id, source, start_time, hidden_at)
                VALUES (?, ?, ?, ?)
            """,
            arguments: [id, source, startTime, hiddenAt]
        )
    }

    private func insertCost(_ db: GRDB.Database, sessionId: String, costUsd: Double?) throws {
        try db.execute(
            sql: "INSERT INTO session_costs (session_id, cost_usd) VALUES (?, ?)",
            arguments: [sessionId, costUsd]
        )
    }
}
