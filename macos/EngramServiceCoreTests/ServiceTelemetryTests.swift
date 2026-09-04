import XCTest
import GRDB
import Darwin
import Foundation
import EngramCoreWrite
@testable import EngramServiceCore

final class ServiceTelemetryTests: XCTestCase {
    func testInitialFtsDrainStopsAfterBoundedConsecutiveFailures_repro() {
        XCTAssertFalse(EngramServiceRunner.shouldStopInitialFtsDrain(consecutiveFailures: 1))
        XCTAssertFalse(EngramServiceRunner.shouldStopInitialFtsDrain(consecutiveFailures: 2))
        XCTAssertTrue(EngramServiceRunner.shouldStopInitialFtsDrain(consecutiveFailures: 3))
    }

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
        // Empty HOME + all shipped source IDs disabled keeps residual phases cheap.
        // Inject failure on initialScanBackfills so maintenance/parents never runs
        // (early inject left that phase hanging). maxFtsDrainIterations: 0 still
        // bounds undrainable FTS after later phases. Outer failedPhaseCount gate
        // still decides success-sample recording.
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
            testHooks: .init(
                failPhaseNamed: "initialScanBackfills",
                maxFtsDrainIterations: 0
            )
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
            snapshot.spans.first(where: { $0.command == "scanPhase.initialScanBackfills" }),
            "injected required phase must emit distinct failure telemetry"
        )
        XCTAssertEqual(failed.ok, false)
        XCTAssertEqual(failed.errorName, "ScanPhaseFailed")
    }

    /// M2: when the core index phase succeeded but a later required phase failed,
    /// status must still record scan success (clear degraded) while telemetry
    /// must not count a full success sample.
    func testRunInitialScanPartialSuccessRecordsStatusWhenCoreIndexOk_repro() async throws {
        let paths = try makeServicePaths()
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
            testHooks: .init(
                failPhaseNamed: "initialScanBackfills",
                maxFtsDrainIterations: 0
            )
        )

        let snapshot = await collector.snapshot()
        XCTAssertEqual(
            snapshot.scanCount,
            0,
            "M2: partial success must not record a full success telemetry sample"
        )
        let indexStatus = try await gate.indexStatus()
        let status = await monitor.status(indexStatus: indexStatus)
        guard case .running = status else {
            return XCTFail(
                "M2: core index succeeded with later phase failure must clear degraded via recordScanSuccess, got \(status)"
            )
        }
    }

    /// Initial scanning has several early-return paths. Memory pressure relief
    /// must still run after all scan-owned allocations unwind, including when a
    /// required phase fails.
    func testRunInitialScanRelievesMallocPressureAfterPhaseFailure() async throws {
        let paths = try makeServicePaths()
        FileManager.default.createFile(atPath: paths.database.path, contents: nil)
        let gate = try ServiceWriterGate(
            databasePath: paths.database.path,
            runtimeDirectory: paths.runtime
        )
        _ = try await gate.performWriteCommand(name: "migrate") { writer in
            try writer.migrate()
            try writer.verifySchemaPresent()
        }

        let relief = MemoryPressureReliefRecorder(releasedBytes: 4096)
        let emptyHome = paths.runtime.deletingLastPathComponent()
            .appendingPathComponent("empty-home", isDirectory: true)
        try FileManager.default.createDirectory(at: emptyHome, withIntermediateDirectories: true)
        let disabledAll = [
            "codex", "claude-code", "copilot", "gemini-cli", "opencode", "iflow",
            "qwen", "qoder", "kimi", "minimax", "lobsterai", "commandcode",
            "cline", "cursor", "vscode", "antigravity", "windsurf",
        ].joined(separator: ",")

        await EngramServiceRunner.runStartupMaintenanceWithMemoryRelief(
            relieveMemoryPressure: { relief.relieve() }
        ) {
            await EngramServiceRunner.runInitialScan(
                gate: gate,
                statusMonitor: ServiceStatusMonitor(),
                environment: [
                    "HOME": emptyHome.path,
                    "ENGRAM_DISABLED_SOURCES": disabledAll,
                ],
                tokenLimitsProvider: { [:] },
                testHooks: .init(
                    failPhaseNamed: "initialScanBackfills",
                    maxFtsDrainIterations: 0
                )
            )
        }

        XCTAssertEqual(relief.callCount, 1)
    }

    /// Each startup phase can accumulate allocator pages even after its local
    /// parser/GRDB objects are released. Reclaim between phases so those empty
    /// pages do not compound into the startup peak.
    func testRunInitialScanPhaseRelievesMallocPressureOnCompletion() async {
        let relief = MemoryPressureReliefRecorder(releasedBytes: 2048)

        let outcome = await EngramServiceRunner.runInitialScanPhase(
            name: "memoryReliefProbe",
            statusMonitor: ServiceStatusMonitor(),
            relieveMemoryPressure: { relief.relieve() }
        ) {
            42
        }

        XCTAssertEqual(outcome.value, 42)
        XCTAssertFalse(outcome.failed)
        XCTAssertFalse(outcome.cancelled)
        XCTAssertEqual(relief.callCount, 1)
    }

    func testPeriodicMaintenanceRelievesMallocPressureOnCompletion() async {
        let relief = MemoryPressureReliefRecorder(releasedBytes: 1024)
        let operationFinished = LockedFlag()

        await EngramServiceRunner.runPeriodicMaintenanceWithMemoryRelief(
            relieveMemoryPressure: { relief.relieve() }
        ) {
            operationFinished.set(true)
        }

        XCTAssertTrue(operationFinished.value())
        XCTAssertEqual(relief.callCount, 1)
    }

    func testRepoDiscoveryThrottleRotatesBoundedBatchesAndHonorsCooldown() {
        let clock = MaintenanceTestClock(Date(timeIntervalSince1970: 10_000))
        let throttle = RepoDiscoveryMaintenanceThrottle(
            batchLimit: 2,
            cooldown: 3_600,
            now: { clock.value() }
        )
        let candidates = (0..<5).map {
            GitRepoCandidate(cwd: "/repo/\($0)", sessionCount: 5 - $0)
        }

        let first = throttle.selectCandidates(candidates)
        XCTAssertEqual(first.map(\.cwd), ["/repo/0", "/repo/1"])
        throttle.recordOutcomes(succeeded: first.map(\.cwd), failed: [])
        let second = throttle.selectCandidates(candidates)
        XCTAssertEqual(second.map(\.cwd), ["/repo/2", "/repo/3"])
        throttle.recordOutcomes(succeeded: second.map(\.cwd), failed: [])
        let third = throttle.selectCandidates(candidates)
        XCTAssertEqual(third.map(\.cwd), ["/repo/4"])
        throttle.recordOutcomes(succeeded: third.map(\.cwd), failed: [])
        XCTAssertTrue(throttle.selectCandidates(candidates).isEmpty)

        clock.advance(by: 3_600)
        XCTAssertEqual(throttle.selectCandidates(candidates).map(\.cwd), ["/repo/0", "/repo/1"])
    }

    /// F3 / REPO-DISCOVERY-COOLDOWN-001: selecting a candidate must not burn
    /// the 6h success window; only a recorded success does.
    func testRepoDiscoveryThrottleDoesNotCoolFailedProbeForSuccessWindow_repro() {
        let clock = MaintenanceTestClock(Date(timeIntervalSince1970: 10_000))
        let throttle = RepoDiscoveryMaintenanceThrottle(
            batchLimit: 1,
            cooldown: 3_600,
            failureCooldown: 60,
            now: { clock.value() }
        )
        let candidates = [
            GitRepoCandidate(cwd: "/repo/missing", sessionCount: 3),
            GitRepoCandidate(cwd: "/repo/ok", sessionCount: 2),
        ]

        XCTAssertEqual(throttle.selectCandidates(candidates).map(\.cwd), ["/repo/missing"])
        XCTAssertEqual(
            throttle.selectCandidates(candidates).map(\.cwd),
            ["/repo/missing"],
            "selectCandidates must not consume cooldown before a probe outcome"
        )

        throttle.recordOutcomes(succeeded: [], failed: ["/repo/missing"])
        XCTAssertEqual(throttle.selectCandidates(candidates).map(\.cwd), ["/repo/ok"])

        clock.advance(by: 59)
        XCTAssertEqual(throttle.selectCandidates(candidates).map(\.cwd), ["/repo/ok"])
        clock.advance(by: 1)
        XCTAssertEqual(throttle.selectCandidates(candidates).map(\.cwd), ["/repo/missing"])

        throttle.recordOutcomes(succeeded: ["/repo/ok"], failed: [])
        XCTAssertEqual(throttle.selectCandidates(candidates).map(\.cwd), ["/repo/missing"])
        clock.advance(by: 3_600)
        XCTAssertEqual(throttle.selectCandidates(candidates).map(\.cwd), ["/repo/missing"])
        throttle.recordOutcomes(succeeded: [], failed: ["/repo/missing"])
        XCTAssertEqual(throttle.selectCandidates(candidates).map(\.cwd), ["/repo/ok"])
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

    func testRunnerUsesListeningThenTopLevelIndexedLifecycleEvents_repro() throws {
        let source = try serviceRunnerSource()
        let listenStart = try XCTUnwrap(source.range(of: "try server.start()"))
        let listenEnd = try XCTUnwrap(
            source.range(of: "let initialInterval", range: listenStart.lowerBound..<source.endIndex)
        )
        let listenBody = String(source[listenStart.lowerBound..<listenEnd.lowerBound])
        XCTAssertTrue(listenBody.contains("emit(ServiceReadyEvent(socket: socketPath))"))

        let readyStructStart = try XCTUnwrap(source.range(of: "private struct ServiceReadyEvent"))
        let readyStructEnd = try XCTUnwrap(
            source.range(of: "private struct ServiceCheckpointEvent", range: readyStructStart.lowerBound..<source.endIndex)
        )
        let readyStruct = String(source[readyStructStart.lowerBound..<readyStructEnd.lowerBound])
        XCTAssertTrue(
            readyStruct.contains(#"let event = "listening""#),
            "the socket-listen notification must not masquerade as initial indexing readiness"
        )

        let initialStart = try XCTUnwrap(source.range(of: "static func runInitialScan("))
        let initialEnd = try XCTUnwrap(
            source.range(of: "private static func elapsedMs", range: initialStart.lowerBound..<source.endIndex)
        )
        let initialBody = String(source[initialStart.lowerBound..<initialEnd.lowerBound])
        XCTAssertTrue(
            initialBody.contains(#"guard event.event != "ready" else { return }"#),
            "the legacy nested ready payload must not reach stdout"
        )
        let completionEvent = try XCTUnwrap(initialBody.range(of: "emit(ServiceIndexEvent("))
        let finalStatusRead = try XCTUnwrap(initialBody.range(of: #"name: "initialScanCompletionStatus""#))
        XCTAssertGreaterThan(
            completionEvent.lowerBound,
            finalStatusRead.lowerBound,
            "the top-level indexed event must carry totals read after the initial scan completes"
        )

        let indexStructStart = try XCTUnwrap(source.range(of: "private struct ServiceIndexEvent"))
        let indexStructEnd = try XCTUnwrap(
            source.range(of: "private struct ServiceIndexErrorEvent", range: indexStructStart.lowerBound..<source.endIndex)
        )
        let indexStruct = String(source[indexStructStart.lowerBound..<indexStructEnd.lowerBound])
        XCTAssertTrue(indexStruct.contains(#"let event = "indexed""#))
        XCTAssertTrue(indexStruct.contains("let total: Int"))
        XCTAssertTrue(indexStruct.contains("let todayParents: Int"))
        XCTAssertFalse(indexStruct.contains("payload"), "app-consumed counters must stay top-level")
    }

    func testOpenCodeLiveSessionsExcludeDispatchedChildrenButKeepContinuedForks_repro() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("engram-live-opencode-role-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let databaseURL = root.appendingPathComponent(".local/share/opencode/opencode.db")
        try FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let updated = Int64(Date().timeIntervalSince1970 * 1_000)
        try await DatabaseQueue(path: databaseURL.path).write { db in
            try db.execute(
                sql: """
                    CREATE TABLE session (
                      id TEXT PRIMARY KEY,
                      parent_id TEXT,
                      agent TEXT,
                      slug TEXT,
                      directory TEXT,
                      title TEXT,
                      time_updated INTEGER NOT NULL,
                      time_archived INTEGER
                    );
                    INSERT INTO session VALUES
                      ('parent', NULL, 'build', 'main', '/repo', 'Main work', ?, NULL),
                      ('task-child', 'parent', 'explore', 'task-research', '/repo', 'Research (@explore subagent)', ?, NULL),
                      ('continued-fork', 'parent', 'build', 'continued-work', '/repo', 'Continue work', ?, NULL);
                    """,
                arguments: [updated, updated, updated]
            )
        }

        let response = try await FileSystemEngramServiceReadProvider(
            homeDirectory: root,
            liveSessionCacheTTL: 0
        ).liveSessions()
        let ids = Set(response.sessions.compactMap(\.sessionId))

        XCTAssertFalse(ids.contains("task-child"), "TaskTool-dispatched children must not consume live-session slots")
        XCTAssertTrue(ids.contains("continued-fork"), "a parent_id alone must not hide a continued fork")
        XCTAssertTrue(ids.contains("parent"))
    }

    func testImplicitArchivedDefaultsHideHistoryAndStillParticipateInOrphanScan_repro() async throws {
        let paths = try makeServicePaths()
        defer { try? FileManager.default.removeItem(at: paths.runtime.deletingLastPathComponent()) }
        let home = paths.runtime.deletingLastPathComponent().appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let gate = try ServiceWriterGate(databasePath: paths.database.path, runtimeDirectory: paths.runtime)
        _ = try await gate.performWriteCommand(name: "migrate") { writer in
            try writer.migrate()
            try writer.write { db in
                for source in ArchivedDefaultOffSources.orderedIDs {
                    try db.execute(
                        sql: """
                            INSERT INTO sessions(id, source, start_time, file_path)
                            VALUES (?, ?, '2026-09-01T00:00:00Z', ?)
                            """,
                        arguments: ["archived-\(source)", source, home.appendingPathComponent("missing-\(source)").path]
                    )
                }
            }
        }

        await runBoundedInitialScan(gate: gate, home: home)

        let rows = try await gate.performReadCommand(name: "verifyImplicitArchivedDefaults") { writer in
            try writer.read { db in
                try Row.fetchAll(
                    db,
                    sql: """
                        SELECT source, hidden_at, orphan_status
                        FROM sessions
                        WHERE source IN ('cline', 'iflow', 'lobsterai')
                        ORDER BY source
                        """
                ).map { row in
                    ArchivedSessionState(
                        source: row["source"],
                        hiddenAt: row["hidden_at"],
                        orphanStatus: row["orphan_status"]
                    )
                }
            }
        }.value
        XCTAssertEqual(rows.map(\.source), ["cline", "iflow", "lobsterai"])
        XCTAssertTrue(rows.allSatisfy { $0.hiddenAt != nil })
        XCTAssertTrue(
            rows.allSatisfy { $0.orphanStatus == "suspect" },
            "default-off sources still need their shipped adapters for missing-file detection"
        )
    }

    func testExplicitlyEnabledArchivedSourceIsNotHiddenAgainAtStartup_repro() async throws {
        let paths = try makeServicePaths()
        defer { try? FileManager.default.removeItem(at: paths.runtime.deletingLastPathComponent()) }
        let home = paths.runtime.deletingLastPathComponent().appendingPathComponent("home", isDirectory: true)
        let settingsURL = home.appendingPathComponent(".engram/settings.json")
        try FileManager.default.createDirectory(
            at: settingsURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try JSONSerialization.data(withJSONObject: [
            "disabledSources": ["cline", "iflow"],
            ArchivedDefaultOffSources.settingsMigrationKey: true,
        ]).write(to: settingsURL)

        let gate = try ServiceWriterGate(databasePath: paths.database.path, runtimeDirectory: paths.runtime)
        _ = try await gate.performWriteCommand(name: "migrate") { writer in
            try writer.migrate()
            try writer.write { db in
                try db.execute(
                    sql: """
                        INSERT INTO sessions(id, source, start_time, file_path)
                        VALUES ('enabled-lobsterai', 'lobsterai', '2026-09-01T00:00:00Z', ?)
                        """,
                    arguments: [home.appendingPathComponent("missing-lobsterai").path]
                )
            }
        }

        await runBoundedInitialScan(gate: gate, home: home, settingsURL: settingsURL)

        let hiddenAt = try await gate.performReadCommand(name: "verifyEnabledArchivedSource") { writer in
            try writer.read { db in
                try String.fetchOne(
                    db,
                    sql: "SELECT hidden_at FROM sessions WHERE id = 'enabled-lobsterai'"
                )
            }
        }.value
        XCTAssertNil(hiddenAt, "an explicit migration marker makes lobsterai enabled and startup must preserve that choice")
    }

    func testConcurrentArchivedSourceEnableWinsOverStartupVisibilitySnapshot_repro() async throws {
        let paths = try makeServicePaths()
        defer { try? FileManager.default.removeItem(at: paths.runtime.deletingLastPathComponent()) }
        let home = paths.runtime.deletingLastPathComponent().appendingPathComponent("home", isDirectory: true)
        let settingsURL = home.appendingPathComponent(".engram/settings.json")
        try FileManager.default.createDirectory(
            at: settingsURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try JSONSerialization.data(withJSONObject: ["disabledSources": [] as [String]])
            .write(to: settingsURL)

        let priorHome = getenv("HOME").map { String(cString: $0) }
        let priorFixedHome = getenv("CFFIXED_USER_HOME").map { String(cString: $0) }
        let priorSettingsPath = getenv("ENGRAM_SETTINGS_PATH").map { String(cString: $0) }
        setenv("HOME", home.path, 1)
        setenv("CFFIXED_USER_HOME", home.path, 1)
        setenv("ENGRAM_SETTINGS_PATH", settingsURL.path, 1)
        defer {
            if let priorHome {
                setenv("HOME", priorHome, 1)
            } else {
                unsetenv("HOME")
            }
            if let priorFixedHome {
                setenv("CFFIXED_USER_HOME", priorFixedHome, 1)
            } else {
                unsetenv("CFFIXED_USER_HOME")
            }
            if let priorSettingsPath {
                setenv("ENGRAM_SETTINGS_PATH", priorSettingsPath, 1)
            } else {
                unsetenv("ENGRAM_SETTINGS_PATH")
            }
        }

        let gate = try ServiceWriterGate(databasePath: paths.database.path, runtimeDirectory: paths.runtime)
        _ = try await gate.performWriteCommand(name: "migrate") { writer in
            try writer.migrate()
            try writer.write { db in
                try db.execute(
                    sql: """
                        INSERT INTO sessions(id, source, start_time, file_path, hidden_at)
                        VALUES ('concurrent-lobsterai', 'lobsterai', '2026-09-01T00:00:00Z', ?, '2026-09-01T00:00:00Z')
                        """,
                    arguments: [home.appendingPathComponent("missing-lobsterai").path]
                )
            }
        }

        let snapshotBarrier = InitialArchivedVisibilitySnapshotBarrier()
        let scanTask = Task {
            await EngramServiceRunner.runInitialScan(
                gate: gate,
                statusMonitor: ServiceStatusMonitor(),
                environment: [
                    "HOME": home.path,
                    "CFFIXED_USER_HOME": home.path,
                    "ENGRAM_SETTINGS_PATH": settingsURL.path,
                ],
                tokenLimitsProvider: { [:] },
                testHooks: .init(
                    maxFtsDrainIterations: 0,
                    afterDisabledSourceConfigurationRead: {
                        await snapshotBarrier.pause()
                    }
                )
            )
        }
        await snapshotBarrier.waitUntilPaused()

        let handler = EngramServiceCommandHandler(writerGate: gate)
        let response = await handler.handle(
            EngramServiceRequestEnvelope(
                command: "setSourceEnabled",
                payload: try JSONEncoder().encode(
                    EngramServiceSetSourceEnabledRequest(source: "lobsterai", enabled: true)
                )
            )
        )
        if case .failure(_, let error) = response {
            await snapshotBarrier.release()
            await scanTask.value
            XCTFail("setSourceEnabled failed: \(error.name): \(error.message)")
            return
        }

        let afterEnable = try await gate.performReadCommand(name: "verifyConcurrentEnable") { writer in
            try writer.read { db in
                try String.fetchOne(
                    db,
                    sql: "SELECT hidden_at FROM sessions WHERE id = 'concurrent-lobsterai'"
                )
            }
        }.value
        XCTAssertNil(afterEnable, "the serialized enable command must unhide history before startup resumes")
        let migratedSettings = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: settingsURL)) as? [String: Any]
        )
        XCTAssertEqual(migratedSettings[ArchivedDefaultOffSources.settingsMigrationKey] as? Bool, true)

        await snapshotBarrier.release()
        await scanTask.value

        let afterStartup = try await gate.performReadCommand(name: "verifyConcurrentStartupVisibility") { writer in
            try writer.read { db in
                try String.fetchOne(
                    db,
                    sql: "SELECT hidden_at FROM sessions WHERE id = 'concurrent-lobsterai'"
                )
            }
        }.value
        XCTAssertNil(afterStartup, "startup must re-check settings under the gate instead of replaying its stale snapshot")
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

    private func serviceRunnerSource() throws -> String {
        let macosRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: macosRoot.appendingPathComponent("EngramService/Core/EngramServiceRunner.swift"),
            encoding: .utf8
        )
    }

    private func runBoundedInitialScan(
        gate: ServiceWriterGate,
        home: URL,
        settingsURL: URL? = nil
    ) async {
        let priorHome = getenv("HOME").map { String(cString: $0) }
        let priorFixedHome = getenv("CFFIXED_USER_HOME").map { String(cString: $0) }
        setenv("HOME", home.path, 1)
        setenv("CFFIXED_USER_HOME", home.path, 1)
        defer {
            if let priorHome {
                setenv("HOME", priorHome, 1)
            } else {
                unsetenv("HOME")
            }
            if let priorFixedHome {
                setenv("CFFIXED_USER_HOME", priorFixedHome, 1)
            } else {
                unsetenv("CFFIXED_USER_HOME")
            }
        }
        var environment = [
            "HOME": home.path,
            "CFFIXED_USER_HOME": home.path,
        ]
        if let settingsURL {
            environment["ENGRAM_SETTINGS_PATH"] = settingsURL.path
        }
        await EngramServiceRunner.runInitialScan(
            gate: gate,
            statusMonitor: ServiceStatusMonitor(),
            environment: environment,
            tokenLimitsProvider: { [:] },
            testHooks: .init(maxFtsDrainIterations: 0)
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

private struct ArchivedSessionState: Sendable {
    let source: String
    let hiddenAt: String?
    let orphanStatus: String?
}

private actor InitialArchivedVisibilitySnapshotBarrier {
    private var paused = false
    private var released = false
    private var pauseWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func pause() async {
        paused = true
        pauseWaiters.forEach { $0.resume() }
        pauseWaiters.removeAll()
        guard !released else { return }
        await withCheckedContinuation { continuation in
            if released {
                continuation.resume()
            } else {
                releaseWaiters.append(continuation)
            }
        }
    }

    func waitUntilPaused() async {
        guard !paused else { return }
        await withCheckedContinuation { continuation in
            pauseWaiters.append(continuation)
        }
    }

    func release() {
        released = true
        releaseWaiters.forEach { $0.resume() }
        releaseWaiters.removeAll()
    }
}

private final class MemoryPressureReliefRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private let releasedBytes: Int
    private var calls = 0

    init(releasedBytes: Int) {
        self.releasedBytes = releasedBytes
    }

    var callCount: Int {
        lock.withLock { calls }
    }

    func relieve() -> Int {
        lock.withLock { calls += 1 }
        return releasedBytes
    }
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false

    func set(_ value: Bool) {
        lock.withLock { flag = value }
    }

    func value() -> Bool {
        lock.withLock { flag }
    }
}

private final class MaintenanceTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date

    init(_ date: Date) {
        self.date = date
    }

    func value() -> Date {
        lock.withLock { date }
    }

    func advance(by interval: TimeInterval) {
        lock.withLock { date = date.addingTimeInterval(interval) }
    }
}
