import GRDB
import XCTest
@testable import EngramCoreWrite

final class StartupUsageCollectorTests: XCTestCase {
    private var tempDB: URL!
    private var writer: EngramDatabaseWriter!

    override func setUpWithError() throws {
        tempDB = FileManager.default.temporaryDirectory
            .appendingPathComponent("startup-usage-\(UUID().uuidString).sqlite")
        writer = try EngramDatabaseWriter(path: tempDB.path)
        try writer.migrate()
    }

    override func tearDownWithError() throws {
        writer = nil
        if let tempDB {
            try? FileManager.default.removeItem(at: tempDB)
        }
        tempDB = nil
    }

    func testCollectorWritesProviderUsageSnapshotsForTrackedCLIs() throws {
        try writer.write { db in
            try insertSession(db, id: "claude-1", source: "claude-code", startTime: "2026-05-24T10:00:00.000Z")
            try insertSession(db, id: "codex-1", source: "codex", startTime: "2026-05-24T10:10:00.000Z")
            try insertSession(db, id: "codex-old", source: "codex", startTime: "2026-05-20T10:10:00.000Z")
            try insertSession(db, id: "gemini-1", source: "gemini-cli", startTime: "2026-05-24T10:20:00.000Z")
            try insertSession(db, id: "ag-1", source: "antigravity", startTime: "2026-05-24T10:30:00.000Z")
            try insertSession(db, id: "open-1", source: "opencode", startTime: "2026-05-24T10:40:00.000Z")
            try insertCost(db, sessionId: "claude-1", model: "claude-sonnet", input: 100, output: 40, cost: 0.24)
            try insertCost(db, sessionId: "codex-1", model: "gpt-5", input: 200, output: 60, cost: 0.36)
            try insertCost(db, sessionId: "codex-old", model: "gpt-5", input: 800, output: 200, cost: 1.00)
            try insertCost(db, sessionId: "gemini-1", model: "gemini-2.5-pro", input: 150, output: 20, cost: 0.18)
            try insertCost(db, sessionId: "ag-1", model: "gemini-2.5-pro", input: 50, output: 10, cost: 0.07)
            try insertCost(db, sessionId: "open-1", model: "opencode", input: 70, output: 20, cost: 0.09)
        }

        let emitted = try WriterStartupUsageCollector(writer: writer, now: {
            ISO8601DateFormatter().date(from: "2026-05-24T12:00:00Z")!
        }).collect()

        XCTAssertEqual(Set(emitted.map(\.source)), ["claude-code", "codex", "gemini-cli", "antigravity", "opencode"])
        XCTAssertEqual(Set(emitted.map(\.metric)), [
            "5h token share",
            "5h token total",
            "7d cost share",
            "7d token share",
            "7d token total"
        ])
        XCTAssertTrue(emitted.allSatisfy { $0.value > 0 && $0.status == "observed" })

        let rows = try writer.read { db in
            try Row.fetchAll(
                db,
                sql: "SELECT source, metric, value, unit, reset_at, status, limit_value FROM usage_snapshots ORDER BY source, metric"
            )
        }
        XCTAssertEqual(rows.count, 25)
        XCTAssertEqual(Set(rows.map { $0["unit"] as String }), ["%", "tokens"])
        XCTAssertEqual(Set(rows.map { $0["status"] as String }), ["observed"])
        XCTAssertTrue(rows.allSatisfy { ($0["limit_value"] as Double?) == nil })
        let codexFiveHour = rows.first { ($0["source"] as String) == "codex" && ($0["metric"] as String) == "5h token share" }
        let codexSevenDay = rows.first { ($0["source"] as String) == "codex" && ($0["metric"] as String) == "7d token share" }
        let codexFiveHourTotal = rows.first { ($0["source"] as String) == "codex" && ($0["metric"] as String) == "5h token total" }
        let codexSevenDayTotal = rows.first { ($0["source"] as String) == "codex" && ($0["metric"] as String) == "7d token total" }
        XCTAssertEqual((codexFiveHour?["value"] as Double?) ?? -1, 36.1, accuracy: 0.1)
        XCTAssertEqual(codexFiveHour?["reset_at"] as String?, "2026-05-24T15:10:00.000Z")
        XCTAssertEqual((codexSevenDay?["value"] as Double?) ?? -1, 73.3, accuracy: 0.1)
        XCTAssertEqual(codexSevenDay?["reset_at"] as String?, "2026-05-27T10:10:00.000Z")
        XCTAssertEqual(codexFiveHourTotal?["value"] as Double?, 260)
        XCTAssertEqual(codexFiveHourTotal?["unit"] as String?, "tokens")
        XCTAssertEqual(codexFiveHourTotal?["reset_at"] as String?, "2026-05-24T15:10:00.000Z")
        XCTAssertEqual(codexSevenDayTotal?["value"] as Double?, 1260)
        XCTAssertEqual(codexSevenDayTotal?["unit"] as String?, "tokens")
        XCTAssertEqual(codexSevenDayTotal?["reset_at"] as String?, "2026-05-27T10:10:00.000Z")

        let emittedCodexFiveHour = emitted.first { $0.source == "codex" && $0.metric == "5h token share" }
        XCTAssertEqual(emittedCodexFiveHour?.resetAt, "2026-05-24T15:10:00.000Z")
        let emittedCodexFiveHourTotal = emitted.first { $0.source == "codex" && $0.metric == "5h token total" }
        XCTAssertEqual(emittedCodexFiveHourTotal?.value, 260)
        XCTAssertEqual(emittedCodexFiveHourTotal?.unit, "tokens")
        XCTAssertEqual(emittedCodexFiveHourTotal?.resetAt, "2026-05-24T15:10:00.000Z")
    }

    func testCollectorKeepsLatestUsageSnapshotsInsteadOfAppendingDuplicates() throws {
        try writer.write { db in
            try insertSession(db, id: "codex-1", source: "codex", startTime: "2026-05-24T10:10:00.000Z")
            try insertCost(db, sessionId: "codex-1", model: "gpt-5", input: 200, output: 60, cost: 0.36)
        }

        let clock = {
            ISO8601DateFormatter().date(from: "2026-05-24T12:00:00Z")!
        }
        _ = try WriterStartupUsageCollector(writer: writer, now: clock).collect()
        _ = try WriterStartupUsageCollector(writer: writer, now: clock).collect()

        let rows = try writer.read { db in
            try Row.fetchAll(
                db,
                sql: """
                SELECT source, metric, COUNT(*) AS count
                FROM usage_snapshots
                GROUP BY source, metric
                ORDER BY source, metric
                """
            )
        }

        XCTAssertEqual(rows.count, 5)
        XCTAssertTrue(rows.allSatisfy { ($0["count"] as Int) == 1 })
    }

    func testCollectorObservesTokenCapableQoderAndClineByDefault() throws {
        try writer.write { db in
            try insertSession(db, id: "qoder-1", source: "qoder", startTime: "2026-05-24T10:10:00.000Z")
            try insertSession(db, id: "cline-1", source: "cline", startTime: "2026-05-24T10:20:00.000Z")
            try insertCost(db, sessionId: "qoder-1", model: "qoder-agent", input: 12, output: 8, cost: 0.0)
            try insertCost(db, sessionId: "cline-1", model: "glm-5", input: 100, output: 0, cost: 0.0)
        }

        let emitted = try WriterStartupUsageCollector(writer: writer, now: {
            ISO8601DateFormatter().date(from: "2026-05-24T12:00:00Z")!
        }).collect()

        let qoderFiveHourTotal = emitted.first { $0.source == "qoder" && $0.metric == "5h token total" }
        XCTAssertEqual(qoderFiveHourTotal?.value, 20)
        XCTAssertEqual(qoderFiveHourTotal?.unit, "tokens")

        let clineFiveHourTotal = emitted.first { $0.source == "cline" && $0.metric == "5h token total" }
        XCTAssertEqual(clineFiveHourTotal?.value, 100)
        XCTAssertEqual(clineFiveHourTotal?.unit, "tokens")

        let rows = try writer.read { db in
            try Row.fetchAll(
                db,
                sql: """
                SELECT source, metric, value, unit
                FROM usage_snapshots
                WHERE source IN ('qoder', 'cline') AND metric IN ('5h token total', '7d token total')
                ORDER BY source, metric
                """
            )
        }
        XCTAssertEqual(rows.count, 4)
        XCTAssertEqual(Set(rows.map { $0["unit"] as String }), ["tokens"])
    }

    func testCollectorObservesTokenCapableQwenKimiAndIflowByDefault() throws {
        try writer.write { db in
            try insertSession(db, id: "qwen-1", source: "qwen", startTime: "2026-05-24T10:10:00.000Z")
            try insertSession(db, id: "kimi-1", source: "kimi", startTime: "2026-05-24T10:20:00.000Z")
            try insertSession(db, id: "iflow-1", source: "iflow", startTime: "2026-05-24T10:30:00.000Z")
            try insertCost(db, sessionId: "qwen-1", model: "qwen-code", input: 100, output: 25, cost: 0.0)
            try insertCost(db, sessionId: "kimi-1", model: "kimi-k2", input: 40, output: 10, cost: 0.0)
            try insertCost(db, sessionId: "iflow-1", model: "iflow-agent", input: 70, output: 30, cost: 0.0)
        }

        let emitted = try WriterStartupUsageCollector(writer: writer, now: {
            ISO8601DateFormatter().date(from: "2026-05-24T12:00:00Z")!
        }).collect()

        let qwenFiveHourTotal = emitted.first { $0.source == "qwen" && $0.metric == "5h token total" }
        XCTAssertEqual(qwenFiveHourTotal?.value, 125)
        XCTAssertEqual(qwenFiveHourTotal?.unit, "tokens")

        let kimiFiveHourTotal = emitted.first { $0.source == "kimi" && $0.metric == "5h token total" }
        XCTAssertEqual(kimiFiveHourTotal?.value, 50)
        XCTAssertEqual(kimiFiveHourTotal?.unit, "tokens")

        let iflowFiveHourTotal = emitted.first { $0.source == "iflow" && $0.metric == "5h token total" }
        XCTAssertEqual(iflowFiveHourTotal?.value, 100)
        XCTAssertEqual(iflowFiveHourTotal?.unit, "tokens")

        let rows = try writer.read { db in
            try Row.fetchAll(
                db,
                sql: """
                SELECT source, metric, value, unit
                FROM usage_snapshots
                WHERE source IN ('qwen', 'kimi', 'iflow') AND metric IN ('5h token total', '7d token total')
                ORDER BY source, metric
                """
            )
        }
        XCTAssertEqual(rows.count, 6)
        XCTAssertEqual(Set(rows.map { $0["unit"] as String }), ["tokens"])
    }

    func testCollectorWritesConfiguredTokenLimitPressureSnapshots() throws {
        try writer.write { db in
            try insertSession(db, id: "codex-critical", source: "codex", startTime: "2026-05-24T10:10:00.000Z")
            try insertSession(db, id: "claude-attention", source: "claude-code", startTime: "2026-05-24T10:20:00.000Z")
            try insertSession(db, id: "gemini-observed", source: "gemini-cli", startTime: "2026-05-24T10:30:00.000Z")
            try insertCost(db, sessionId: "codex-critical", model: "gpt-5", input: 920, output: 40, cost: 0.36)
            try insertCost(db, sessionId: "claude-attention", model: "claude-sonnet", input: 760, output: 20, cost: 0.24)
            try insertCost(db, sessionId: "gemini-observed", model: "gemini-2.5-pro", input: 100, output: 20, cost: 0.12)
        }

        let emitted = try WriterStartupUsageCollector(
            writer: writer,
            now: { ISO8601DateFormatter().date(from: "2026-05-24T12:00:00Z")! },
            tokenLimits: [
                "codex": .init(fiveHourTokens: 1_000, weeklyTokens: nil),
                "claude-code": .init(fiveHourTokens: 1_000, weeklyTokens: nil),
                "gemini-cli": .init(fiveHourTokens: 1_000, weeklyTokens: nil)
            ]
        ).collect()

        let pressureRows = try writer.read { db in
            try Row.fetchAll(
                db,
                sql: """
                SELECT source, metric, value, unit, reset_at, status, limit_value
                FROM usage_snapshots
                WHERE metric = '5h token pressure'
                ORDER BY source
                """
            )
        }

        XCTAssertEqual(pressureRows.count, 3)
        let claude = pressureRows.first { ($0["source"] as String) == "claude-code" }
        XCTAssertEqual(claude?["value"] as Double?, 78.0)
        XCTAssertEqual(claude?["unit"] as String?, "%")
        XCTAssertEqual(claude?["limit_value"] as Double?, 100.0)
        XCTAssertEqual(claude?["status"] as String?, "attention")
        XCTAssertEqual(claude?["reset_at"] as String?, "2026-05-24T15:20:00.000Z")

        let codex = pressureRows.first { ($0["source"] as String) == "codex" }
        XCTAssertEqual(codex?["value"] as Double?, 96.0)
        XCTAssertEqual(codex?["unit"] as String?, "%")
        XCTAssertEqual(codex?["limit_value"] as Double?, 100.0)
        XCTAssertEqual(codex?["status"] as String?, "critical")
        XCTAssertEqual(codex?["reset_at"] as String?, "2026-05-24T15:10:00.000Z")

        let gemini = pressureRows.first { ($0["source"] as String) == "gemini-cli" }
        XCTAssertEqual(gemini?["value"] as Double?, 12.0)
        XCTAssertEqual(gemini?["unit"] as String?, "%")
        XCTAssertEqual(gemini?["limit_value"] as Double?, 100.0)
        XCTAssertEqual(gemini?["status"] as String?, "ok")
        XCTAssertEqual(gemini?["reset_at"] as String?, "2026-05-24T15:30:00.000Z")

        let emittedCodex = emitted.first { $0.source == "codex" && $0.metric == "5h token pressure" }
        XCTAssertEqual(emittedCodex?.value, 96.0)
        XCTAssertEqual(emittedCodex?.limit, 100.0)
        XCTAssertEqual(emittedCodex?.status, "critical")

        let emittedGemini = emitted.first { $0.source == "gemini-cli" && $0.metric == "5h token pressure" }
        XCTAssertEqual(emittedGemini?.value, 12.0)
        XCTAssertEqual(emittedGemini?.limit, 100.0)
        XCTAssertEqual(emittedGemini?.status, "ok")
    }

    func testCollectorWritesOkTokenPressureWhenConfiguredLimitIsBelowAlertThreshold() throws {
        try writer.write { db in
            try insertSession(db, id: "codex-ok", source: "codex", startTime: "2026-05-24T10:10:00.000Z")
            try insertCost(db, sessionId: "codex-ok", model: "gpt-5", input: 100, output: 20, cost: 0.04)
        }

        let emitted = try WriterStartupUsageCollector(
            writer: writer,
            now: { ISO8601DateFormatter().date(from: "2026-05-24T12:00:00Z")! },
            tokenLimits: [
                "codex": .init(fiveHourTokens: 1_000, weeklyTokens: nil)
            ]
        ).collect()

        let row = try writer.read { db in
            try Row.fetchOne(
                db,
                sql: """
                SELECT source, metric, value, unit, reset_at, status, limit_value
                FROM usage_snapshots
                WHERE source = 'codex' AND metric = '5h token pressure'
                """
            )
        }

        XCTAssertEqual(row?["value"] as Double?, 12.0)
        XCTAssertEqual(row?["unit"] as String?, "%")
        XCTAssertEqual(row?["limit_value"] as Double?, 100.0)
        XCTAssertEqual(row?["status"] as String?, "ok")
        XCTAssertEqual(row?["reset_at"] as String?, "2026-05-24T15:10:00.000Z")

        let emittedCodex = emitted.first { $0.source == "codex" && $0.metric == "5h token pressure" }
        XCTAssertEqual(emittedCodex?.value, 12.0)
        XCTAssertEqual(emittedCodex?.limit, 100.0)
        XCTAssertEqual(emittedCodex?.status, "ok")
    }

    func testCollectorNormalizesSourceBeforeApplyingTokenLimits() throws {
        try writer.write { db in
            try insertSession(db, id: "codex-drift", source: " CODEX ", startTime: "2026-05-24T10:10:00.000Z")
            try insertCost(db, sessionId: "codex-drift", model: "gpt-5", input: 900, output: 20, cost: 0.04)
        }

        let emitted = try WriterStartupUsageCollector(
            writer: writer,
            now: { ISO8601DateFormatter().date(from: "2026-05-24T12:00:00Z")! },
            tokenLimits: [
                "codex": .init(fiveHourTokens: 1_000, weeklyTokens: nil)
            ]
        ).collect()

        let pressureRow = try writer.read { db in
            try Row.fetchOne(
                db,
                sql: """
                SELECT source, metric, value, unit, reset_at, status, limit_value
                FROM usage_snapshots
                WHERE metric = '5h token pressure'
                """
            )
        }

        XCTAssertEqual(pressureRow?["source"] as String?, "codex")
        XCTAssertEqual(pressureRow?["value"] as Double?, 92.0)
        XCTAssertEqual(pressureRow?["unit"] as String?, "%")
        XCTAssertEqual(pressureRow?["limit_value"] as Double?, 100.0)
        XCTAssertEqual(pressureRow?["status"] as String?, "critical")
        XCTAssertEqual(pressureRow?["reset_at"] as String?, "2026-05-24T15:10:00.000Z")

        let emittedPressure = emitted.first { $0.metric == "5h token pressure" }
        XCTAssertEqual(emittedPressure?.source, "codex")
        XCTAssertEqual(emittedPressure?.value, 92.0)
        XCTAssertEqual(emittedPressure?.status, "critical")
    }

    private func insertSession(
        _ db: Database,
        id: String,
        source: String,
        startTime: String
    ) throws {
        try db.execute(
            sql: """
            INSERT INTO sessions(id, source, start_time, cwd, file_path, indexed_at)
            VALUES (?, ?, ?, '/repo', '/tmp/\(id).jsonl', ?)
            """,
            arguments: [id, source, startTime, startTime]
        )
    }

    private func insertCost(
        _ db: Database,
        sessionId: String,
        model: String,
        input: Int,
        output: Int,
        cost: Double
    ) throws {
        try db.execute(
            sql: """
            INSERT INTO session_costs(
              session_id, model, input_tokens, output_tokens, cache_read_tokens,
              cache_creation_tokens, cost_usd, computed_at
            ) VALUES (?, ?, ?, ?, 0, 0, ?, '2026-05-24T12:00:00.000Z')
            """,
            arguments: [sessionId, model, input, output, cost]
        )
    }
}
