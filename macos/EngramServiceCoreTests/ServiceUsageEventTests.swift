import XCTest
import GRDB
import EngramCoreWrite
@testable import EngramServiceCore

final class ServiceUsageEventTests: XCTestCase {
    func testRunnerReadsUsageTokenLimitsFromEnvironmentJSON() {
        let limits = EngramServiceRunner.readUsageTokenLimits(environment: [
            "ENGRAM_USAGE_TOKEN_LIMITS": """
            {
              "codex": {"fiveHourTokens": 1000, "weeklyTokens": 5000},
              "claude-code": {"fiveHourTokens": 750}
            }
            """
        ])

        XCTAssertEqual(limits["codex"]?.fiveHourTokens, 1_000)
        XCTAssertEqual(limits["codex"]?.weeklyTokens, 5_000)
        XCTAssertEqual(limits["claude-code"]?.fiveHourTokens, 750)
        XCTAssertNil(limits["claude-code"]?.weeklyTokens)
    }

    func testRunnerNormalizesUsageTokenLimitSourceKeysFromEnvironmentJSON() {
        let limits = EngramServiceRunner.readUsageTokenLimits(environment: [
            "ENGRAM_USAGE_TOKEN_LIMITS": """
            {
              " Codex ": {"fiveHourTokens": 1000},
              "CLAUDE-CODE": {"weeklyTokens": 5000}
            }
            """
        ])

        XCTAssertEqual(limits["codex"]?.fiveHourTokens, 1_000)
        XCTAssertEqual(limits["claude-code"]?.weeklyTokens, 5_000)
        XCTAssertNil(limits[" Codex "])
        XCTAssertNil(limits["CLAUDE-CODE"])
    }

    func testRunnerReadsUsageTokenLimitsFromSettingsJSON() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("runner-usage-settings-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let settingsURL = directory.appendingPathComponent("settings.json")
        try """
        {
          "usageTokenLimits": {
            "codex": {"fiveHourTokens": 1000, "weeklyTokens": 5000},
            "claude-code": {"weeklyTokens": 7500}
          }
        }
        """.data(using: .utf8)!.write(to: settingsURL)

        let limits = EngramServiceRunner.readUsageTokenLimits(
            environment: [:],
            settingsURL: settingsURL
        )

        XCTAssertEqual(limits["codex"]?.fiveHourTokens, 1_000)
        XCTAssertEqual(limits["codex"]?.weeklyTokens, 5_000)
        XCTAssertNil(limits["claude-code"]?.fiveHourTokens)
        XCTAssertEqual(limits["claude-code"]?.weeklyTokens, 7_500)
    }

    func testUsageEventCarriesResetAtForQuotaSnapshots() throws {
        let event = ServiceUsageEvent(snapshots: [
            StartupUsageSnapshot(
                source: "codex",
                metric: "5h token total",
                value: 1_260,
                unit: "tokens",
                resetAt: "2026-04-23T07:00:00Z",
                limit: 100.0,
                status: "observed"
            )
        ])

        let data = try JSONEncoder().encode(event)
        let decoded = try JSONDecoder().decode(EngramServiceEvent.self, from: data)

        XCTAssertEqual(decoded.usage?.first?.source, "codex")
        XCTAssertEqual(decoded.usage?.first?.metric, "5h token total")
        XCTAssertEqual(decoded.usage?.first?.value, 1_260)
        XCTAssertEqual(decoded.usage?.first?.unit, "tokens")
        XCTAssertEqual(decoded.usage?.first?.limit, 100.0)
        XCTAssertEqual(decoded.usage?.first?.resetAt, "2026-04-23T07:00:00Z")
        XCTAssertEqual(decoded.usage?.first?.status, "observed")
    }

    func testRunnerUsageCollectionWritesSnapshotsAndEmitsTokenTotals() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("runner-usage-\(UUID().uuidString)", isDirectory: true)
        let runtime = root.appendingPathComponent("run", isDirectory: true)
        let database = root.appendingPathComponent("index.sqlite")
        try FileManager.default.createDirectory(
            at: runtime,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        defer {
            try? FileManager.default.removeItem(at: root)
        }

        let gate = try ServiceWriterGate(
            databasePath: database.path,
            runtimeDirectory: runtime,
            queueTimeoutNanoseconds: 1_000_000_000
        )
        _ = try await gate.performWriteCommand(name: "seedUsage") { writer in
            try writer.migrate()
            try writer.write { db in
                try db.execute(
                    sql: """
                    INSERT INTO sessions(id, source, start_time, cwd, file_path, indexed_at)
                    VALUES ('codex-usage', 'codex', '2026-05-24T10:10:00.000Z', '/repo', '/tmp/codex.jsonl', '2026-05-24T10:10:00.000Z')
                    """
                )
                try db.execute(
                    sql: """
                    INSERT INTO session_costs(
                      session_id, model, input_tokens, output_tokens, cache_read_tokens,
                      cache_creation_tokens, cost_usd, computed_at
                    ) VALUES ('codex-usage', 'gpt-5', 1200, 60, 0, 0, 0.36, '2026-05-24T12:00:00.000Z')
                    """
                )
            }
        }

        var emitted: [StartupUsageSnapshot] = []
        try await EngramServiceRunner.collectUsage(
            gate: gate,
            now: { ISO8601DateFormatter().date(from: "2026-05-24T12:00:00Z")! },
            tokenLimits: ["codex": .init(fiveHourTokens: 1_300, weeklyTokens: nil)],
            emit: { emitted = $0 }
        )

        let emittedTotal = emitted.first { $0.source == "codex" && $0.metric == "5h token total" }
        XCTAssertEqual(emittedTotal?.value, 1_260)
        XCTAssertEqual(emittedTotal?.unit, "tokens")
        let emittedPressure = emitted.first { $0.source == "codex" && $0.metric == "5h token pressure" }
        XCTAssertEqual(emittedPressure?.value, 96.9)
        XCTAssertEqual(emittedPressure?.limit, 100.0)
        XCTAssertEqual(emittedPressure?.status, "critical")

        let usageCounts = try await gate.performWriteCommand(name: "readUsage") { writer in
            try writer.read { db in
                let row = try Row.fetchOne(
                    db,
                    sql: """
                    SELECT
                      COUNT(*) FILTER (WHERE metric = '5h token total' AND unit = 'tokens') AS totals,
                      COUNT(*) FILTER (WHERE metric = '5h token pressure' AND status = 'critical' AND limit_value = 100.0) AS pressure
                    FROM usage_snapshots
                    WHERE source = 'codex'
                    """
                )
                return (
                    totals: row?["totals"] as Int? ?? 0,
                    pressure: row?["pressure"] as Int? ?? 0
                )
            }
        }
        XCTAssertEqual(usageCounts.value.totals, 1)
        XCTAssertEqual(usageCounts.value.pressure, 1)
    }

    func testRunnerUsageCollectionIncludesConfiguredCopilotTokenLimits() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("runner-copilot-usage-\(UUID().uuidString)", isDirectory: true)
        let runtime = root.appendingPathComponent("run", isDirectory: true)
        let database = root.appendingPathComponent("index.sqlite")
        try FileManager.default.createDirectory(
            at: runtime,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        defer {
            try? FileManager.default.removeItem(at: root)
        }

        let gate = try ServiceWriterGate(
            databasePath: database.path,
            runtimeDirectory: runtime,
            queueTimeoutNanoseconds: 1_000_000_000
        )
        _ = try await gate.performWriteCommand(name: "seedCopilotUsage") { writer in
            try writer.migrate()
            try writer.write { db in
                try db.execute(
                    sql: """
                    INSERT INTO sessions(id, source, start_time, cwd, file_path, indexed_at)
                    VALUES ('copilot-usage', 'copilot', '2026-05-24T10:10:00.000Z', '/repo', '/tmp/copilot.jsonl', '2026-05-24T10:10:00.000Z')
                    """
                )
                try db.execute(
                    sql: """
                    INSERT INTO session_costs(
                      session_id, model, input_tokens, output_tokens, cache_read_tokens,
                      cache_creation_tokens, cost_usd, computed_at
                    ) VALUES ('copilot-usage', 'gpt-5', 800, 200, 0, 0, 0.00, '2026-05-24T12:00:00.000Z')
                    """
                )
            }
        }

        var emitted: [StartupUsageSnapshot] = []
        try await EngramServiceRunner.collectUsage(
            gate: gate,
            now: { ISO8601DateFormatter().date(from: "2026-05-24T12:00:00Z")! },
            tokenLimits: ["copilot": .init(fiveHourTokens: 1_250, weeklyTokens: nil)],
            emit: { emitted = $0 }
        )

        let emittedTotal = emitted.first { $0.source == "copilot" && $0.metric == "5h token total" }
        XCTAssertEqual(emittedTotal?.value, 1_000)
        XCTAssertEqual(emittedTotal?.unit, "tokens")

        let emittedPressure = emitted.first { $0.source == "copilot" && $0.metric == "5h token pressure" }
        XCTAssertEqual(emittedPressure?.value, 80.0)
        XCTAssertEqual(emittedPressure?.limit, 100.0)
        XCTAssertEqual(emittedPressure?.status, "attention")
    }

    func testRunnerUsageCollectionNormalizesConfiguredTokenLimitSourceKeys() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("runner-normalized-limit-source-\(UUID().uuidString)", isDirectory: true)
        let runtime = root.appendingPathComponent("run", isDirectory: true)
        let database = root.appendingPathComponent("index.sqlite")
        try FileManager.default.createDirectory(
            at: runtime,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        defer {
            try? FileManager.default.removeItem(at: root)
        }

        let gate = try ServiceWriterGate(
            databasePath: database.path,
            runtimeDirectory: runtime,
            queueTimeoutNanoseconds: 1_000_000_000
        )
        _ = try await gate.performWriteCommand(name: "seedNormalizedLimitSourceUsage") { writer in
            try writer.migrate()
            try writer.write { db in
                try db.execute(
                    sql: """
                    INSERT INTO sessions(id, source, start_time, cwd, file_path, indexed_at)
                    VALUES ('codex-normalized-limit', 'codex', '2026-05-24T10:10:00.000Z', '/repo', '/tmp/codex.jsonl', '2026-05-24T10:10:00.000Z')
                    """
                )
                try db.execute(
                    sql: """
                    INSERT INTO session_costs(
                      session_id, model, input_tokens, output_tokens, cache_read_tokens,
                      cache_creation_tokens, cost_usd, computed_at
                    ) VALUES ('codex-normalized-limit', 'gpt-5', 1200, 60, 0, 0, 0.36, '2026-05-24T12:00:00.000Z')
                    """
                )
            }
        }

        var emitted: [StartupUsageSnapshot] = []
        try await EngramServiceRunner.collectUsage(
            gate: gate,
            now: { ISO8601DateFormatter().date(from: "2026-05-24T12:00:00Z")! },
            tokenLimits: [" Codex ": .init(fiveHourTokens: 1_300, weeklyTokens: nil)],
            emit: { emitted = $0 }
        )

        let emittedPressure = emitted.first { $0.source == "codex" && $0.metric == "5h token pressure" }
        XCTAssertEqual(emittedPressure?.value, 96.9)
        XCTAssertEqual(emittedPressure?.limit, 100.0)
        XCTAssertEqual(emittedPressure?.status, "critical")
    }

    func testRunnerUsageCollectionIncludesExplicitlyConfiguredExtraSource() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("runner-extra-source-usage-\(UUID().uuidString)", isDirectory: true)
        let runtime = root.appendingPathComponent("run", isDirectory: true)
        let database = root.appendingPathComponent("index.sqlite")
        try FileManager.default.createDirectory(
            at: runtime,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        defer {
            try? FileManager.default.removeItem(at: root)
        }

        let gate = try ServiceWriterGate(
            databasePath: database.path,
            runtimeDirectory: runtime,
            queueTimeoutNanoseconds: 1_000_000_000
        )
        _ = try await gate.performWriteCommand(name: "seedExtraSourceUsage") { writer in
            try writer.migrate()
            try writer.write { db in
                try db.execute(
                    sql: """
                    INSERT INTO sessions(id, source, start_time, cwd, file_path, indexed_at)
                    VALUES ('qwen-usage', 'qwen', '2026-05-24T10:10:00.000Z', '/repo', '/tmp/qwen.jsonl', '2026-05-24T10:10:00.000Z')
                    """
                )
                try db.execute(
                    sql: """
                    INSERT INTO session_costs(
                      session_id, model, input_tokens, output_tokens, cache_read_tokens,
                      cache_creation_tokens, cost_usd, computed_at
                    ) VALUES ('qwen-usage', 'qwen3-coder', 400, 100, 0, 0, 0.00, '2026-05-24T12:00:00.000Z')
                    """
                )
            }
        }

        var emitted: [StartupUsageSnapshot] = []
        try await EngramServiceRunner.collectUsage(
            gate: gate,
            now: { ISO8601DateFormatter().date(from: "2026-05-24T12:00:00Z")! },
            tokenLimits: ["qwen": .init(fiveHourTokens: 1_000, weeklyTokens: nil)],
            emit: { emitted = $0 }
        )

        let emittedTotal = emitted.first { $0.source == "qwen" && $0.metric == "5h token total" }
        XCTAssertEqual(emittedTotal?.value, 500)
        XCTAssertEqual(emittedTotal?.unit, "tokens")

        let emittedPressure = emitted.first { $0.source == "qwen" && $0.metric == "5h token pressure" }
        XCTAssertEqual(emittedPressure?.value, 50.0)
        XCTAssertEqual(emittedPressure?.limit, 100.0)
        XCTAssertEqual(emittedPressure?.status, "ok")
    }

    func testRunnerUsageCollectionIncludesUnconfiguredAdapterSourcesWithTokenData() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("runner-unconfigured-source-usage-\(UUID().uuidString)", isDirectory: true)
        let runtime = root.appendingPathComponent("run", isDirectory: true)
        let database = root.appendingPathComponent("index.sqlite")
        try FileManager.default.createDirectory(
            at: runtime,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        defer {
            try? FileManager.default.removeItem(at: root)
        }

        let gate = try ServiceWriterGate(
            databasePath: database.path,
            runtimeDirectory: runtime,
            queueTimeoutNanoseconds: 1_000_000_000
        )
        _ = try await gate.performWriteCommand(name: "seedCommandCodeUsage") { writer in
            try writer.migrate()
            try writer.write { db in
                try db.execute(
                    sql: """
                    INSERT INTO sessions(id, source, start_time, cwd, file_path, indexed_at)
                    VALUES ('commandcode-usage', 'commandcode', '2026-05-24T10:10:00.000Z', '/repo', '/tmp/commandcode.jsonl', '2026-05-24T10:10:00.000Z')
                    """
                )
                try db.execute(
                    sql: """
                    INSERT INTO session_costs(
                      session_id, model, input_tokens, output_tokens, cache_read_tokens,
                      cache_creation_tokens, cost_usd, computed_at
                    ) VALUES ('commandcode-usage', 'gpt-5', 300, 120, 0, 0, 0.00, '2026-05-24T12:00:00.000Z')
                    """
                )
            }
        }

        var emitted: [StartupUsageSnapshot] = []
        try await EngramServiceRunner.collectUsage(
            gate: gate,
            now: { ISO8601DateFormatter().date(from: "2026-05-24T12:00:00Z")! },
            emit: { emitted = $0 }
        )

        let emittedTotal = emitted.first { $0.source == "commandcode" && $0.metric == "5h token total" }
        XCTAssertEqual(emittedTotal?.value, 420)
        XCTAssertEqual(emittedTotal?.unit, "tokens")
    }

    func testRefreshUsageCommandCollectsConfiguredTokenLimitsImmediately() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("refresh-usage-\(UUID().uuidString)", isDirectory: true)
        let runtime = root.appendingPathComponent("run", isDirectory: true)
        let database = root.appendingPathComponent("index.sqlite")
        try FileManager.default.createDirectory(
            at: runtime,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        defer {
            try? FileManager.default.removeItem(at: root)
        }

        let gate = try ServiceWriterGate(
            databasePath: database.path,
            runtimeDirectory: runtime,
            queueTimeoutNanoseconds: 1_000_000_000
        )
        _ = try await gate.performWriteCommand(name: "seedRefreshUsage") { writer in
            try writer.migrate()
            try writer.write { db in
                try db.execute(
                    sql: """
                    INSERT INTO sessions(id, source, start_time, cwd, file_path, indexed_at)
                    VALUES ('codex-refresh', 'codex', '2026-05-24T10:10:00.000Z', '/repo', '/tmp/codex.jsonl', '2026-05-24T10:10:00.000Z')
                    """
                )
                try db.execute(
                    sql: """
                    INSERT INTO session_costs(
                      session_id, model, input_tokens, output_tokens, cache_read_tokens,
                      cache_creation_tokens, cost_usd, computed_at
                    ) VALUES ('codex-refresh', 'gpt-5', 1200, 60, 0, 0, 0.36, '2026-05-24T12:00:00.000Z')
                    """
                )
            }
        }

        let emitted = LockedUsageSnapshots()
        let handler = EngramServiceCommandHandler(
            writerGate: gate,
            usageNow: { ISO8601DateFormatter().date(from: "2026-05-24T12:00:00Z")! },
            usageTokenLimitsProvider: { ["codex": .init(fiveHourTokens: 1_300, weeklyTokens: nil)] },
            usageEmitter: { emitted.set($0) }
        )

        let response = await handler.handle(EngramServiceRequestEnvelope(command: "refreshUsage"))

        guard case .success(_, let data, let generation) = response else {
            return XCTFail("refreshUsage should succeed")
        }
        XCTAssertNotNil(generation, "refreshUsage writes snapshots and should advance database generation")
        let decoded = try JSONDecoder().decode(EngramServiceRefreshUsageResponse.self, from: data)
        XCTAssertEqual(decoded.snapshotCount, emitted.value.count)
        XCTAssertEqual(decoded.sources, ["codex"])
        XCTAssertEqual(decoded.pressure.map(\.metric), ["5h token pressure"])
        XCTAssertEqual(decoded.pressure.first?.source, "codex")
        XCTAssertEqual(decoded.pressure.first?.status, "critical")

        let emittedPressure = emitted.value.first { $0.source == "codex" && $0.metric == "5h token pressure" }
        XCTAssertEqual(emittedPressure?.value, 96.9)
        XCTAssertEqual(emittedPressure?.limit, 100.0)
        XCTAssertEqual(emittedPressure?.status, "critical")
    }
}

private final class LockedUsageSnapshots: @unchecked Sendable {
    private let lock = NSLock()
    private var snapshots: [StartupUsageSnapshot] = []

    var value: [StartupUsageSnapshot] {
        lock.lock()
        defer { lock.unlock() }
        return snapshots
    }

    func set(_ value: [StartupUsageSnapshot]) {
        lock.lock()
        snapshots = value
        lock.unlock()
    }
}
