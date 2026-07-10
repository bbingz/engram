import XCTest
import GRDB
import Foundation
import EngramCoreWrite
@testable import EngramServiceCore

final class ServiceTelemetryTests: XCTestCase {
    // MARK: - Collector unit tests

    func testRingBufferEvictsOldestAt200() async {
        let collector = ServiceTelemetryCollector()
        for i in 0..<250 {
            await collector.record(span: span(command: "search", durationMs: Double(i)))
        }
        let snapshot = await collector.snapshot()
        XCTAssertEqual(snapshot.spans.count, 200)
        // Newest-first: the most recent span (i=249) is first; oldest retained
        // is i=50, so i=0..49 were evicted.
        XCTAssertEqual(snapshot.spans.first?.durationMs, 249)
        XCTAssertEqual(snapshot.spans.last?.durationMs, 50)
    }

    func testPercentilesAndMaxPerCommand() async {
        let collector = ServiceTelemetryCollector()
        for ms in 1...100 {
            await collector.record(span: span(command: "search", durationMs: Double(ms)))
        }
        let snapshot = await collector.snapshot()
        let search = try? XCTUnwrap(snapshot.commands.first(where: { $0.command == "search" }))
        XCTAssertEqual(search?.count, 100)
        XCTAssertEqual(search?.maxMs, 100)
        // Nearest-rank: p50 of 1...100 = 50, p95 = 95.
        XCTAssertEqual(search?.p50Ms, 50)
        XCTAssertEqual(search?.p95Ms, 95)
        XCTAssertEqual(search?.errorCount, 0)
    }

    func testErrorSpanIncrementsErrorCount() async {
        let collector = ServiceTelemetryCollector()
        await collector.record(span: span(command: "search", durationMs: 5, ok: true))
        await collector.record(span: span(command: "search", durationMs: 7, ok: false, errorName: "Boom"))
        let snapshot = await collector.snapshot()
        let search = snapshot.commands.first(where: { $0.command == "search" })
        XCTAssertEqual(search?.count, 2)
        XCTAssertEqual(search?.errorCount, 1)
        XCTAssertTrue(snapshot.spans.contains(where: { $0.ok == false && $0.errorName == "Boom" }))
    }

    func testRecordScanUpdatesCounters() async {
        let collector = ServiceTelemetryCollector()
        await collector.recordScan(durationMs: 12.5, indexed: 3, total: 42)
        await collector.recordScan(durationMs: 9.0, indexed: 1, total: 43)
        let snapshot = await collector.snapshot()
        XCTAssertEqual(snapshot.scanCount, 2)
        XCTAssertEqual(snapshot.lastScanDurationMs, 9.0)
        XCTAssertEqual(snapshot.lastScanIndexed, 1)
        XCTAssertEqual(snapshot.lastScanTotal, 43)
        XCTAssertNotNil(snapshot.lastScanAt)
    }

    /// M02: a failed initial-scan phase must emit distinct failure telemetry and
    /// must not be counted as a successful scan sample.
    func testFailedScanPhaseDoesNotRecordSuccessSample_repro() async {
        let collector = ServiceTelemetryCollector()
        let startedAt = "2026-07-10T12:00:00.000Z"
        await collector.recordFailedScanPhase(
            phase: "initialScanIndex",
            durationMs: 42.5,
            startedAt: startedAt
        )
        let snapshot = await collector.snapshot()

        XCTAssertEqual(snapshot.scanCount, 0, "failed phase must not increment scanCount")
        XCTAssertNil(snapshot.lastScanDurationMs)
        XCTAssertNil(snapshot.lastScanAt)
        XCTAssertEqual(snapshot.lastScanIndexed, 0)
        XCTAssertEqual(snapshot.lastScanTotal, 0)

        let failed = snapshot.spans.first(where: { $0.command == "scanPhase.initialScanIndex" })
        XCTAssertNotNil(failed, "failed phase must appear as distinct span telemetry")
        XCTAssertEqual(failed?.ok, false)
        XCTAssertEqual(failed?.errorName, "ScanPhaseFailed")
        XCTAssertEqual(failed?.durationMs, 42.5)
        XCTAssertEqual(failed?.startedAt, startedAt)

        let latency = snapshot.commands.first(where: { $0.command == "scanPhase.initialScanIndex" })
        XCTAssertEqual(latency?.errorCount, 1)
        XCTAssertEqual(latency?.count, 1)
    }

    func testFailedScanPhaseUsesSuppliedStartedAtNotRecordTime() async {
        let collector = ServiceTelemetryCollector()
        let startedAt = "2026-01-01T00:00:00.000Z"
        await collector.recordFailedScanPhase(phase: "initialFtsDrain", durationMs: 7, startedAt: startedAt)
        let snapshot = await collector.snapshot()
        XCTAssertEqual(snapshot.spans.first?.startedAt, startedAt)
    }

    func testSuccessScanSampleStillRecordsAfterFailedPhaseTelemetry() async {
        let collector = ServiceTelemetryCollector()
        await collector.recordFailedScanPhase(
            phase: "initialScanOrphans",
            durationMs: 3,
            startedAt: "2026-07-10T00:00:00.000Z"
        )
        await collector.recordScan(durationMs: 11, indexed: 2, total: 9)
        let snapshot = await collector.snapshot()
        XCTAssertEqual(snapshot.scanCount, 1)
        XCTAssertEqual(snapshot.lastScanIndexed, 2)
        XCTAssertTrue(snapshot.spans.contains(where: { $0.command == "scanPhase.initialScanOrphans" && $0.ok == false }))
    }

    /// M02 behavioral: outer `runInitialScan` orchestration with a required
    /// phase failure must not record a success scan sample. Would fail if
    /// finalize always called `recordScan` regardless of `failedPhaseCount`.
    func testRunInitialScanOuterOrchestrationPhaseFailureOmitsSuccessSample() async throws {
        let paths = try makeServicePaths()
        // Touch the DB file so EngramDatabaseWriter can open it.
        FileManager.default.createFile(atPath: paths.database.path, contents: nil)
        let gate = try ServiceWriterGate(
            databasePath: paths.database.path,
            runtimeDirectory: paths.runtime
        )
        _ = try await gate.performWriteCommand(name: "migrate") { writer in
            try writer.migrate()
            try writer.verifySchemaPresent()
        }

        let collector = ServiceTelemetryCollector()
        let monitor = ServiceStatusMonitor()
        // Empty HOME + all shipped source IDs disabled keeps residual phases cheap
        // after inject. Explicit list (EngramServiceCoreTests cannot use
        // SessionAdapterFactory); keep complete enough that no default adapter runs.
        let emptyHome = paths.runtime.deletingLastPathComponent()
            .appendingPathComponent("empty-home", isDirectory: true)
        try FileManager.default.createDirectory(at: emptyHome, withIntermediateDirectories: true)
        let disabledAll = [
            "codex", "claude-code", "copilot", "gemini-cli", "opencode", "iflow",
            "qwen", "qoder", "kimi", "minimax", "lobsterai", "commandcode",
            "cline", "cursor", "vscode", "antigravity", "windsurf",
        ].joined(separator: ",")

        await EngramServiceRunner.runInitialScan(
            gate: gate,
            statusMonitor: monitor,
            telemetry: collector,
            environment: [
                "HOME": emptyHome.path,
                "ENGRAM_DISABLED_SOURCES": disabledAll,
            ],
            tokenLimitsProvider: { [:] },
            testHooks: .init(failPhaseNamed: "usageParserBackfillCheck")
        )

        let snapshot = await collector.snapshot()
        XCTAssertEqual(
            snapshot.scanCount,
            0,
            "outer runInitialScan must not record success when a required phase failed"
        )
        XCTAssertNil(snapshot.lastScanDurationMs)
        XCTAssertNil(snapshot.lastScanAt)
        let failed = try XCTUnwrap(
            snapshot.spans.first(where: { $0.command == "scanPhase.usageParserBackfillCheck" }),
            "injected required phase must emit distinct failure telemetry"
        )
        XCTAssertEqual(failed.ok, false)
        XCTAssertEqual(failed.errorName, "ScanPhaseFailed")
    }

    /// L01: stdout event encoding must go through JSONEncoder so quotes/newlines
    /// in error text cannot break the JSON line.
    func testStdoutEventEncodingEscapesQuotesAndControlCharacters() throws {
        struct Event: Encodable {
            let event: String
            let stage: String
            let error: String
        }
        let rawError = "migrate failed: path \"/tmp/a\"\nnext line\t\u{0008}"
        let line = try EngramServiceRunner.encodeStdoutJSON(
            Event(event: "fatal", stage: "migrate", error: rawError)
        )
        let data = try XCTUnwrap(line.data(using: .utf8))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["event"] as? String, "fatal")
        XCTAssertEqual(object["stage"] as? String, "migrate")
        XCTAssertEqual(object["error"] as? String, rawError)
        XCTAssertFalse(line.contains("\n"), "structured stdout must be a single JSON line")
        XCTAssertTrue(line.contains("\\n") || line.contains("\\u000a") || (object["error"] as? String) == rawError)
    }

    func testStdoutCheckpointEventEncodingIncludesOptionalError() throws {
        struct Checkpoint: Encodable {
            let event: String
            let mode: String
            let ok: Bool
            let error: String?
        }
        let okLine = try EngramServiceRunner.encodeStdoutJSON(
            Checkpoint(event: "checkpoint", mode: "PASSIVE", ok: true, error: nil)
        )
        let okObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(okLine.utf8)) as? [String: Any]
        )
        XCTAssertEqual(okObject["ok"] as? Bool, true)
        XCTAssertNil(okObject["error"])

        let failLine = try EngramServiceRunner.encodeStdoutJSON(
            Checkpoint(event: "checkpoint", mode: "PASSIVE", ok: false, error: "boom \"x\"")
        )
        let failObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(failLine.utf8)) as? [String: Any]
        )
        XCTAssertEqual(failObject["ok"] as? Bool, false)
        XCTAssertEqual(failObject["error"] as? String, "boom \"x\"")
    }

    // MARK: - Handler dispatch instrumentation

    func testHandlerRecordsSpanOnDispatchAndExcludesStatusAndTelemetry() async throws {
        let paths = try makeServicePaths()
        try seedSessionsFixture(at: paths.database.path)
        let gate = try ServiceWriterGate(databasePath: paths.database.path, runtimeDirectory: paths.runtime)
        let collector = ServiceTelemetryCollector()
        // Default Empty read provider: `sources` returns [] without touching the
        // SQLite read provider, so this exercises span recording/exclusion
        // without the EngramCoreRead/Write duplicate-GRDB host crash.
        let handler = EngramServiceCommandHandler(writerGate: gate, telemetry: collector)

        _ = await handler.handle(request("sources"))
        _ = await handler.handle(request("status"))
        _ = await handler.handle(request("telemetry"))
        _ = await handler.handle(request("costs"))

        let snapshot = await collector.snapshot()
        // sources recorded; status (poll noise) + telemetry (self) + costs (budget
        // poll noise) excluded.
        XCTAssertTrue(snapshot.spans.contains(where: { $0.command == "sources" }))
        XCTAssertFalse(snapshot.spans.contains(where: { $0.command == "status" }))
        XCTAssertFalse(snapshot.spans.contains(where: { $0.command == "telemetry" }))
        XCTAssertFalse(snapshot.spans.contains(where: { $0.command == "costs" }))
        XCTAssertTrue(snapshot.commands.contains(where: { $0.command == "sources" }))
    }

    func testHandlerRecordsErrorSpanForFailedCommand() async throws {
        let paths = try makeServicePaths()
        try seedSessionsFixture(at: paths.database.path)
        let gate = try ServiceWriterGate(databasePath: paths.database.path, runtimeDirectory: paths.runtime)
        let collector = ServiceTelemetryCollector()
        let handler = EngramServiceCommandHandler(writerGate: gate, telemetry: collector)

        _ = await handler.handle(request("totally.unknown.command"))

        let snapshot = await collector.snapshot()
        let failed = snapshot.spans.first(where: { $0.command == "totally.unknown.command" })
        XCTAssertNotNil(failed)
        XCTAssertEqual(failed?.ok, false)
        XCTAssertNotNil(failed?.errorName)
        let latency = snapshot.commands.first(where: { $0.command == "totally.unknown.command" })
        XCTAssertEqual(latency?.errorCount, 1)
    }

    // MARK: - IPC round-trip

    func testTelemetryCommandRoundTripsOverIPC() async throws {
        let paths = try makeServicePaths()
        try seedSessionsFixture(at: paths.database.path)
        let gate = try ServiceWriterGate(databasePath: paths.database.path, runtimeDirectory: paths.runtime)
        let collector = ServiceTelemetryCollector()
        await collector.recordScan(durationMs: 7.0, indexed: 2, total: 5)
        await collector.record(span: span(command: "search", durationMs: 3.0))
        // Default Empty read provider; the `telemetry` command reads the
        // collector (process state), not the SQLite read provider.
        let handler = EngramServiceCommandHandler(writerGate: gate, telemetry: collector)
        let server = UnixSocketServiceServer(socketPath: paths.socket.path) { req in
            await handler.handle(req)
        }
        try server.start()
        defer { server.stop() }

        let client = EngramServiceClient(transport: UnixSocketEngramServiceTransport(socketPath: paths.socket.path))
        let snapshot = try await client.telemetry()

        XCTAssertEqual(snapshot.scanCount, 1)
        XCTAssertEqual(snapshot.lastScanIndexed, 2)
        XCTAssertEqual(snapshot.lastScanTotal, 5)
        XCTAssertTrue(snapshot.spans.contains(where: { $0.command == "search" }))
    }

    // MARK: - Helpers

    private func span(
        command: String,
        durationMs: Double,
        ok: Bool = true,
        errorName: String? = nil
    ) -> ServiceSpan {
        ServiceSpan(
            command: command,
            startedAt: "2026-06-15T00:00:00.000Z",
            durationMs: durationMs,
            ok: ok,
            errorName: errorName
        )
    }

    private func request(_ command: String) -> EngramServiceRequestEnvelope {
        EngramServiceRequestEnvelope(command: command, payload: Data("{}".utf8))
    }

    private func makeServicePaths() throws -> (runtime: URL, socket: URL, database: URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("engram-telemetry-\(UUID().uuidString.prefix(8))", isDirectory: true)
        let runtime = root.appendingPathComponent("run", isDirectory: true)
        try FileManager.default.createDirectory(
            at: runtime,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        return (
            runtime,
            runtime.appendingPathComponent("service.sock"),
            root.appendingPathComponent("service.sqlite")
        )
    }

    private func seedSessionsFixture(at path: String) throws {
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
        }
    }
}
