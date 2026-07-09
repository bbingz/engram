import XCTest
@testable import EngramServiceCore
import EngramCoreWrite
import GRDB

/// Wave-6 task 6: periodic FTS optimize cadence + loop isolation.
final class FtsOptimizeCadenceTests: XCTestCase {
    func testRunnerPeriodicLoopWiresCadenceGatedFtsOptimize() throws {
        let source = try serviceCoreSource("EngramService/Core/EngramServiceRunner.swift")
        let start = try XCTUnwrap(source.range(of: "private static func runIndexingLoop("))
        let end = try XCTUnwrap(
            source.range(of: "/// V2 composition root", options: [], range: start.lowerBound..<source.endIndex)
        )
        let body = String(source[start.lowerBound..<end.lowerBound])

        XCTAssertTrue(
            body.contains("runPeriodicFtsOptimizeBestEffort(gate: gate)"),
            "long-running service must eventually merge FTS segments from the periodic loop"
        )
        XCTAssertTrue(
            source.contains(#"performWriteCommand(name: "periodicFtsOptimize")"#),
            "periodic optimize must go through the single-writer gate"
        )
        XCTAssertTrue(
            source.contains("optimizeFtsIfDue()"),
            "periodic path must use the interval + signature cadence wrapper"
        )
        XCTAssertFalse(
            body.contains("try database.optimizeFts()") || body.contains("StartupBackfills.optimizeFts("),
            "periodic path must not call un-gated optimizeFts every 5-min tick"
        )
    }

    func testPeriodicFtsOptimizeBestEffortSurvivesOptimizeFailure() async throws {
        let gate = try await makeMigratedGate()

        // Drop FTS tables so the optimize SQL fails when the cadence gate allows a run.
        _ = try await gate.performWriteCommand(name: "break_fts") { writer in
            try writer.write { db in
                try db.execute(sql: "DROP TABLE IF EXISTS sessions_fts")
                try db.execute(sql: "DROP TABLE IF EXISTS insights_fts")
            }
        }

        // Must not throw: loop isolation requires the best-effort helper to swallow
        // optimize failures (same style as backup / embedding helpers).
        await EngramServiceRunner.runPeriodicFtsOptimizeBestEffort(gate: gate)

        // Gate remains usable after the failed optimize attempt.
        let ping = try await gate.performWriteCommand(name: "post_failure_ping") { _ in
            "ok"
        }
        XCTAssertEqual(ping.value, "ok")
    }

    func testOptimizeFtsIfDueThroughWriterGateHonorsCadence() async throws {
        let gate = try await makeMigratedGate()
        let t0 = ISO8601DateFormatter().date(from: "2026-07-09T12:00:00Z")!
        let t1h = t0.addingTimeInterval(60 * 60)
        let minInterval: TimeInterval = 24 * 60 * 60

        _ = try await gate.performWriteCommand(name: "seed") { writer in
            try writer.write { db in
                try db.execute(
                    sql: """
                    INSERT INTO sessions(
                      id, source, start_time, file_path, tier, sync_version, indexed_at
                    ) VALUES (
                      's1', 'codex', '2026-07-01T00:00:00Z', '/tmp/s1.jsonl',
                      'normal', 1, '2026-07-01T00:00:00Z'
                    )
                    """
                )
            }
        }

        let first = try await gate.performWriteCommand(name: "optimize_first") { writer in
            try writer.optimizeFtsIfDue(now: t0, minInterval: minInterval)
        }.value
        XCTAssertTrue(first, "first due attempt should run")

        let second = try await gate.performWriteCommand(name: "optimize_early") { writer in
            try writer.optimizeFtsIfDue(now: t1h, minInterval: minInterval)
        }.value
        XCTAssertFalse(second, "within interval must skip")
    }

    // MARK: - Helpers

    private func serviceCoreSource(_ relativePath: String) throws -> String {
        let thisFile = URL(fileURLWithPath: #filePath)
        let macosRoot = thisFile
            .deletingLastPathComponent() // EngramServiceCoreTests
            .deletingLastPathComponent() // macos
        let url = macosRoot.appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func makeMigratedGate() async throws -> ServiceWriterGate {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("fts-optimize-cadence-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }
        let database = root.appendingPathComponent("index.sqlite")
        let runtime = root.appendingPathComponent("runtime", isDirectory: true)
        try FileManager.default.createDirectory(
            at: runtime,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let gate = try ServiceWriterGate(
            databasePath: database.path,
            runtimeDirectory: runtime
        )
        _ = try await gate.performWriteCommand(name: "migrate") { writer in
            try writer.migrate()
        }
        return gate
    }
}
