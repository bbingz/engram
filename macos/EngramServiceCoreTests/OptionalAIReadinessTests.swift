import Foundation
import XCTest
import EngramCoreRead
import EngramCoreWrite
@testable import EngramServiceCore

final class OptionalAIReadinessTests: XCTestCase {
    func testInitialRequiredReadinessContainsNoAwaitedEmbeddingWork() throws {
        let source = try runnerSource()
        let body = try section(source, start: "static func runInitialScan(", end: "private static func elapsedMs")
        XCTAssertFalse(body.contains("runSessionEmbeddingBackfillBestEffort("))
        XCTAssertFalse(body.contains("runInsightEmbeddingBackfillBestEffort("))
        XCTAssertFalse(body.contains("hasPendingEmbeddingBackfill("))
        XCTAssertTrue(body.contains("initialFtsDrain"), "required FTS remains in the readiness path")
        XCTAssertTrue(body.contains("recordScanSuccess()"))
    }

    func testPeriodicIndexingContainsNoAwaitedEmbeddingWorkOrUngatedBacklogQuery() throws {
        let source = try runnerSource()
        let body = try section(source, start: "private static func runOnePeriodicIndexCycle(", end: "static func adaptersExcludingDisabled(")
        XCTAssertFalse(body.contains("runSessionEmbeddingBackfillBestEffort("))
        XCTAssertFalse(body.contains("runInsightEmbeddingBackfillBestEffort("))
        XCTAssertFalse(body.contains("hasPendingEmbeddingBackfill("))
        XCTAssertTrue(body.contains("drainRecoverableFtsJobs("))
        XCTAssertTrue(body.contains("runArchiveV2IndexCycle("))
    }

    func testCompositionOwnsAndCancelsIndependentOptionalMaintenanceTask() throws {
        let source = try runnerSource()
        let body = try section(source, start: "let initialScanTask = Task", end: "// Stop accepting commands before cancelling")
        XCTAssertTrue(body.contains("let embeddingMaintenanceTask = Task"))
        XCTAssertTrue(body.contains("runOptionalAIMaintenanceLoop(initialScanTask: initialScanTask)"))
        XCTAssertTrue(body.contains("embeddingMaintenanceTask.cancel()"))
        XCTAssertFalse(body.contains("await embeddingMaintenanceTask.value"), "required workers never join provider work")
        XCTAssertTrue(body.contains("backgroundSessionEmbeddingBackfill"))
        XCTAssertTrue(body.contains("backgroundInsightEmbeddingBackfill"))
    }

    func testMaintenanceWaitsForRequiredScanThenRunsBoundedSequentialCycles() async {
        let scanRelease = OptionalAITestBarrier()
        let firstCycle = expectation(description: "first optional cycle")
        let state = OptionalAITestCounter()
        let initial = Task { await scanRelease.wait() }
        let loop = Task {
            await EngramServiceRunner.runOptionalAIMaintenanceLoop(
                initialScanTask: initial,
                sleep: {
                    await state.didSleep()
                    throw CancellationError()
                },
                operation: {
                    await state.didRun()
                    firstCycle.fulfill()
                }
            )
        }
        await Task.yield()
        let before = await state.snapshot()
        XCTAssertEqual(before.runs, 0)
        await scanRelease.open()
        await fulfillment(of: [firstCycle], timeout: 1)
        await loop.value
        let after = await state.snapshot()
        XCTAssertEqual(after.runs, 1)
        XCTAssertEqual(after.sleeps, 1, "one bounded batch precedes each scheduling delay")
    }

    func testCancelledMaintenanceDoesNotStartAfterRequiredScanUnwinds() async {
        let scanRelease = OptionalAITestBarrier()
        let state = OptionalAITestCounter()
        let initial = Task { await scanRelease.wait() }
        let loop = Task {
            await EngramServiceRunner.runOptionalAIMaintenanceLoop(initialScanTask: initial) {
                await state.didRun()
            }
        }
        loop.cancel()
        await scanRelease.open()
        await loop.value
        let after = await state.snapshot()
        XCTAssertEqual(after.runs, 0)
    }

    func testSuspendedOptionalWorkDoesNotBlockOtherRequiredScanWaiters() async {
        let release = OptionalAITestBarrier()
        let initial = Task<Void, Never> {}
        let optionalEntered = expectation(description: "optional provider suspended")
        let requiredStarted = expectation(description: "required indexing can proceed")
        let loop = Task {
            await EngramServiceRunner.runOptionalAIMaintenanceLoop(
                initialScanTask: initial,
                sleep: { throw CancellationError() }
            ) {
                optionalEntered.fulfill()
                await release.wait()
            }
        }
        await fulfillment(of: [optionalEntered], timeout: 1)
        let required = Task {
            await EngramServiceRunner.runAfterInitialScan(initialScanTask: initial) {
                requiredStarted.fulfill()
            }
        }
        await fulfillment(of: [requiredStarted], timeout: 1)
        await required.value
        loop.cancel()
        await release.open()
        await loop.value
    }

    func testNoProviderSkipsBothBacklogsAndFactoryWithoutOpeningProductSchema() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        // Intentionally unmigrated: either candidate query would throw.
        let gate = try ServiceWriterGate(databasePath: fixture.database.path, runtimeDirectory: fixture.runtime)
        let factory: @Sendable (EmbeddingConfig) -> any EmbeddingProvider = { _ in
            XCTFail("no-provider must skip provider construction and candidate queries")
            return OptionalAIUnexpectedProvider()
        }
        let sessions = try await EngramServiceRunner.backfillSessionEmbeddingsOnce(
            gate: gate, environment: fixture.environment, providerFactory: factory,
            backoff: EmbeddingMaintenanceBackoff()
        )
        let insights = try await EngramServiceRunner.backfillInsightEmbeddingsOnce(
            gate: gate, environment: fixture.environment, providerFactory: factory,
            backoff: EmbeddingMaintenanceBackoff()
        )
        XCTAssertEqual(sessions, 0)
        XCTAssertEqual(insights, 0)
        let generation = await gate.currentDatabaseGeneration()
        XCTAssertEqual(generation, 0)
    }

    func testProviderCooldownSkipsBothBacklogsBeforeSchemaReadAndFactory() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let gate = try ServiceWriterGate(databasePath: fixture.database.path, runtimeDirectory: fixture.runtime)
        var environment = fixture.environment
        environment["ENGRAM_EMBEDDING_API_KEY"] = "synthetic-test-key"
        environment["ENGRAM_EMBEDDING_BASE_URL"] = "https://provider.invalid/v1"
        environment["ENGRAM_EMBEDDING_MODEL"] = "optional-readiness"
        let config = try XCTUnwrap(EmbeddingSettings.load(environment: environment))
        let backoff = EmbeddingMaintenanceBackoff()
        _ = backoff.recordFailure(providerKey: EmbeddingCircuitBreaker.providerKey(for: config))
        let factory: @Sendable (EmbeddingConfig) -> any EmbeddingProvider = { _ in
            XCTFail("cooldown must precede provider construction and candidate queries")
            return OptionalAIUnexpectedProvider()
        }
        let sessions = try await EngramServiceRunner.backfillSessionEmbeddingsOnce(
            gate: gate, environment: environment, providerFactory: factory, backoff: backoff
        )
        let insights = try await EngramServiceRunner.backfillInsightEmbeddingsOnce(
            gate: gate, environment: environment, providerFactory: factory, backoff: backoff
        )
        XCTAssertEqual(sessions, 0)
        XCTAssertEqual(insights, 0)
        let generation = await gate.currentDatabaseGeneration()
        XCTAssertEqual(generation, 0)
    }

    func testExplicitShutdownCancelsOptionalWorkBeforeWriterDrainAndJoinsIt() throws {
        let source = try runnerSource()
        let body = try section(source, start: "// Stop accepting commands before cancelling", end: "static func cancelAndAwaitCheckpointTask")
        let cancel = try XCTUnwrap(body.range(of: "embeddingMaintenanceTask.cancel()"))
        let clientDrain = try XCTUnwrap(body.range(of: "server.drainClientHandlers("))
        let join = try XCTUnwrap(body.range(of: "await embeddingMaintenanceTask.value"))
        let writerDrain = try XCTUnwrap(body.range(of: "await waitForShutdownWriterIdle(gate: gate)"))
        XCTAssertLessThan(cancel.lowerBound, clientDrain.lowerBound)
        XCTAssertLessThan(cancel.lowerBound, join.lowerBound)
        XCTAssertLessThan(join.lowerBound, writerDrain.lowerBound)
    }

    func testRealShutdownCancelsOptionalTaskBeforeWaitingForItsHeldWriter() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let entered = expectation(description: "optional fixture holds writer")
        let cancelled = expectation(description: "optional task cancelled before writer drain")
        let release = OptionalAITestBarrier()
        let runner = Task {
            try await EngramServiceRunner.run(
                arguments: ["--service-socket", fixture.runtime.appendingPathComponent("service.sock").path,
                            "--database-path", fixture.database.path],
                environment: runnerEnvironment(fixture.environment),
                testHooks: .init(optionalAIMaintenance: { gate in
                    await withTaskCancellationHandler {
                        _ = try? await gate.performWriteCommand(name: "optionalFixtureHeldWriter") { _ in
                            entered.fulfill()
                            await release.wait()
                        }
                    } onCancel: { cancelled.fulfill() }
                })
            )
        }
        await fulfillment(of: [entered], timeout: 5)
        runner.cancel()
        await fulfillment(of: [cancelled], timeout: 1)
        await release.open()
        try await runner.value
        XCTAssertNoThrow(try ServiceWriterGate(databasePath: fixture.database.path, runtimeDirectory: fixture.runtime))
    }

    func testRealShutdownJoinsCancelledOptionalWorkBeforeReturning() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let entered = expectation(description: "optional fixture provider entered")
        let cancelled = expectation(description: "optional fixture provider cancelled")
        let release = OptionalAITestBarrier()
        let state = OptionalAITestCounter()
        let runner = Task {
            try await EngramServiceRunner.run(
                arguments: ["--service-socket", fixture.runtime.appendingPathComponent("service.sock").path,
                            "--database-path", fixture.database.path],
                environment: runnerEnvironment(fixture.environment),
                testHooks: .init(optionalAIMaintenance: { _ in
                    await withTaskCancellationHandler {
                        entered.fulfill()
                        await release.wait()
                    } onCancel: { cancelled.fulfill() }
                })
            )
            await state.didRun()
        }
        await fulfillment(of: [entered], timeout: 5)
        runner.cancel()
        await fulfillment(of: [cancelled], timeout: 3)
        try await Task.sleep(nanoseconds: 100_000_000)
        let beforeRelease = await state.snapshot()
        XCTAssertEqual(beforeRelease.runs, 0, "run must retain ownership until cancelled optional work has unwound")
        await release.open()
        try await runner.value
        let afterRelease = await state.snapshot()
        XCTAssertEqual(afterRelease.runs, 1)
        XCTAssertNoThrow(try ServiceWriterGate(databasePath: fixture.database.path, runtimeDirectory: fixture.runtime))
    }

    private func runnerSource() throws -> String {
        let macos = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: macos.appendingPathComponent("EngramService/Core/EngramServiceRunner.swift"), encoding: .utf8)
    }

    private func section(_ source: String, start: String, end: String) throws -> String {
        let lower = try XCTUnwrap(source.range(of: start)).lowerBound
        let upper = try XCTUnwrap(source.range(of: end, range: lower..<source.endIndex)).lowerBound
        return String(source[lower..<upper])
    }

    private func makeFixture() throws -> (root: URL, runtime: URL, database: URL, environment: [String: String]) {
        let root = URL(fileURLWithPath: "/tmp").appendingPathComponent("e-ai-\(UUID().uuidString.prefix(8))")
        let runtime = root.appendingPathComponent("runtime")
        try FileManager.default.createDirectory(at: runtime, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let environment = [
            "HOME": root.path,
            "ENGRAM_SETTINGS_PATH": root.appendingPathComponent("settings.json").path,
            "ENGRAM_RUNTIME_AI_SECRETS_PATH": root.appendingPathComponent("absent-test-secrets.json").path,
        ]
        return (root, runtime, root.appendingPathComponent("index.sqlite"), environment)
    }

    private func runnerEnvironment(_ fixture: [String: String]) -> [String: String] {
        var environment = fixture
        environment["CFFIXED_USER_HOME"] = fixture["HOME"]
        environment["XCTestConfigurationFilePath"] = "/tmp/fixture.xctestconfiguration"
        environment["ENGRAM_REMOTE_OFFLOAD_ENABLED"] = "false"
        environment["ENGRAM_DISABLED_SOURCES"] = [
            "codex", "claude-code", "copilot", "gemini-cli", "opencode", "iflow",
            "qwen", "qoder", "kimi", "minimax", "lobsterai", "commandcode",
            "cline", "cursor", "vscode", "antigravity", "windsurf",
        ].joined(separator: ",")
        return environment
    }
}

private actor OptionalAITestCounter {
    private var runs = 0
    private var sleeps = 0
    func didRun() { runs += 1 }
    func didSleep() { sleeps += 1 }
    func snapshot() -> (runs: Int, sleeps: Int) { (runs, sleeps) }
}

private actor OptionalAITestBarrier {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
}

private struct OptionalAIUnexpectedProvider: EmbeddingProvider {
    let model = "unexpected"
    let dimension = 1
    func embed(_ texts: [String]) async throws -> [[Float]] {
        XCTFail("no network work is allowed in this fixture")
        throw CancellationError()
    }
}
