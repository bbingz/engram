import XCTest
import GRDB
import Foundation
import EngramCoreWrite
@testable import EngramServiceCore

/// Behavioral long-op IPC/handler tests (hard-gate regression coverage).
final class ProjectMoveLongOpIPCTests: XCTestCase {
    override func tearDown() {
        for id in [
            "preflight-cache", "preflight-conflict", "gate-hold-op", "batch-unsafe-op",
            "writer-busy-term", "capacity-a", "capacity-b", "capacity-c",
        ] {
            ProjectMoveBatchCancelRegistry.shared.remove(operationId: id)
        }
        // Restore default capacity after admission tests.
        ProjectMoveBatchCancelRegistry.shared.replaceConfigForTests(.default)
        super.tearDown()
    }

    // MARK: - Handler preflight terminalization (real handler)

    func testHandlerPreflightFailureIsTerminalForSameOperationId_repro() async throws {
        try await withTemporaryHome { home in
            let paths = try makePaths()
            try migrateDatabase(at: paths.database.path)
            let gate = try ServiceWriterGate(
                databasePath: paths.database.path,
                runtimeDirectory: paths.runtime
            )
            let handler = EngramServiceCommandHandler(writerGate: gate)
            let operationId = "preflight-cache"

            // Symlink under HOME that resolves outside — use link.path itself.
            let link = home.appendingPathComponent("escape-link")
            try FileManager.default.createSymbolicLink(
                atPath: link.path,
                withDestinationPath: "/etc"
            )
            let src = link.path
            let dst = home.appendingPathComponent(".claude/projects/elsewhere").path

            let request = EngramServiceRequestEnvelope(
                command: "projectMove",
                payload: try JSONEncoder().encode(EngramServiceProjectMoveRequest(
                    src: src,
                    dst: dst,
                    dryRun: true,
                    force: true,
                    auditNote: nil,
                    actor: "test",
                    operationId: operationId
                ))
            )

            let first = await handler.handle(request)
            guard case .failure(_, let error1) = first else {
                return XCTFail("first invalid projectMove must fail confinement, got success")
            }
            XCTAssertEqual(error1.name, "InvalidRequest")
            XCTAssertTrue(
                error1.message.contains("outside the home directory"),
                error1.message
            )

            // Replace link so the same src path would pass confinement if re-run.
            try FileManager.default.removeItem(at: link)
            let inside = home.appendingPathComponent(".claude/projects/inside", isDirectory: true)
            try FileManager.default.createDirectory(at: inside, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(
                atPath: link.path,
                withDestinationPath: inside.path
            )

            // Second same-ID request must return original cached failure (timeout race).
            let second = await withTimeout(seconds: 2) {
                await handler.handle(request)
            }
            guard case .failure(_, let error2)? = second else {
                return XCTFail(
                    "second request must return cached failure within timeout (got \(String(describing: second)))"
                )
            }
            XCTAssertEqual(error2.name, error1.name)
            XCTAssertEqual(error2.message, error1.message)
        }
    }

    func testHandlerPreflightFingerprintConflictOnReusedOperationId_repro() async throws {
        try await withTemporaryHome { home in
            let paths = try makePaths()
            try migrateDatabase(at: paths.database.path)
            let gate = try ServiceWriterGate(
                databasePath: paths.database.path,
                runtimeDirectory: paths.runtime
            )
            let handler = EngramServiceCommandHandler(writerGate: gate)
            let operationId = "preflight-conflict"

            let firstRequest = EngramServiceRequestEnvelope(
                command: "projectMove",
                payload: try JSONEncoder().encode(EngramServiceProjectMoveRequest(
                    src: "/etc/a",
                    dst: "/tmp/a",
                    dryRun: true,
                    force: true,
                    auditNote: nil,
                    actor: "test",
                    operationId: operationId
                ))
            )
            let first = await handler.handle(firstRequest)
            guard case .failure = first else {
                return XCTFail("first invalid request must fail")
            }

            let secondRequest = EngramServiceRequestEnvelope(
                command: "projectMove",
                payload: try JSONEncoder().encode(EngramServiceProjectMoveRequest(
                    src: home.appendingPathComponent(".claude/projects/x").path,
                    dst: home.appendingPathComponent(".claude/projects/y").path,
                    dryRun: true,
                    force: false,
                    auditNote: nil,
                    actor: "app",
                    operationId: operationId
                ))
            )
            let second = await handler.handle(secondRequest)
            guard case .failure(_, let error) = second else {
                return XCTFail("conflicting fingerprint must fail")
            }
            XCTAssertEqual(error.name, "InvalidRequest")
            XCTAssertTrue(error.message.contains("operation_id already used"), error.message)
        }
    }

    // MARK: - Producer gate ownership

    func testProducerRetainsWriterGateAfterClientWaiterDetach_repro() async throws {
        try await withTemporaryHome { home in
            let paths = try makePaths()
            try migrateDatabase(at: paths.database.path)
            let src = home.appendingPathComponent(".claude/projects/gate-old", isDirectory: true)
            let dst = home.appendingPathComponent(".claude/projects/gate-new", isDirectory: true)
            try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)

            let gate = try ServiceWriterGate(
                databasePath: paths.database.path,
                runtimeDirectory: paths.runtime,
                queueTimeoutNanoseconds: 0
            )
            let stallBox = StallBox()
            defer { Task { await stallBox.release() } }

            let producerHoldsGate = expectation(description: "producer holds gate")
            let hooks = ProjectMoveLongOpHooks(
                onProducerHoldsGate: { producerHoldsGate.fulfill() },
                stallWhileHoldingGate: { await stallBox.waitUntilReleased() },
                batchRunOverride: nil
            )
            let handler = EngramServiceCommandHandler(writerGate: gate, longOpHooks: hooks)
            let operationId = "gate-hold-op"
            let writeEntered = WriteEnteredFlag()

            let request = EngramServiceRequestEnvelope(
                command: "projectMove",
                payload: try JSONEncoder().encode(EngramServiceProjectMoveRequest(
                    src: src.path,
                    dst: dst.path,
                    dryRun: true,
                    force: false,
                    auditNote: nil,
                    actor: "test",
                    operationId: operationId
                ))
            )

            let clientTask = Task { await handler.handle(request) }
            await fulfillment(of: [producerHoldsGate], timeout: 5)

            clientTask.cancel()
            // Await client detach causally (no fixed sleep): waiter state must clear.
            _ = await clientTask.result
            XCTAssertEqual(
                ProjectMoveBatchCancelRegistry.shared.waiterStateCountForTests(),
                0,
                "client detach must clear waiter state"
            )
            XCTAssertFalse(
                ProjectMoveBatchCancelRegistry.shared.shouldStop(operationId: operationId),
                "client cancel must not request operation cancel"
            )
            XCTAssertTrue(
                ProjectMoveBatchCancelRegistry.shared.isRunningForTests(operationId),
                "producer must still own the running operation after client detach"
            )

            let writeFinished = expectation(description: "unrelated write finished")
            let writeTask = Task {
                _ = try await gate.performWriteCommand(name: "setFavorite") { _ in
                    writeEntered.mark()
                    return "done"
                }
                writeFinished.fulfill()
            }

            let queued = await waitUntil(timeout: 5) {
                await gate.queuedWriteWaiterCountForTesting() >= 1
            }
            XCTAssertTrue(queued, "unrelated writer must enqueue behind producer-held gate")
            XCTAssertFalse(writeEntered.value)

            await stallBox.release()
            await fulfillment(of: [writeFinished], timeout: 5)
            XCTAssertTrue(writeEntered.value)
            _ = await writeTask.result

            // Wait for producer terminal so tearDown cannot race late completeTerminal.
            let producerSettled = await waitUntil(timeout: 5) {
                !ProjectMoveBatchCancelRegistry.shared.isRunningForTests(operationId)
                    || ProjectMoveBatchCancelRegistry.shared.hasTerminalForTests(operationId)
            }
            XCTAssertTrue(producerSettled, "producer must reach terminal before test ends")
        }
    }

    // MARK: - WriterBusy terminal is not reconnectable (handler + envelope)

    func testHandlerWriterBusyTerminalIsNotReconnectable_repro() async throws {
        try await withTemporaryHome { home in
            let paths = try makePaths()
            try migrateDatabase(at: paths.database.path)
            let src = home.appendingPathComponent(".claude/projects/wb-src", isDirectory: true)
            let dst = home.appendingPathComponent(".claude/projects/wb-dst", isDirectory: true)
            try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)

            // Hold the gate so the long-op producer's performWriteCommand hits writerBusy.
            let gate = try ServiceWriterGate(
                databasePath: paths.database.path,
                runtimeDirectory: paths.runtime,
                queueTimeoutNanoseconds: 50_000_000
            )
            let hold = StallBox()
            defer { Task { await hold.release() } }
            let holderEntered = expectation(description: "holder entered gate")
            let holdTask = Task {
                _ = try await gate.performWriteCommand(name: "hold") { _ in
                    holderEntered.fulfill()
                    await hold.waitUntilReleased()
                    return "held"
                }
            }
            await fulfillment(of: [holderEntered], timeout: 5)

            let handler = EngramServiceCommandHandler(writerGate: gate)
            let operationId = "writer-busy-term"
            let request = EngramServiceRequestEnvelope(
                command: "projectMove",
                payload: try JSONEncoder().encode(EngramServiceProjectMoveRequest(
                    src: src.path,
                    dst: dst.path,
                    dryRun: true,
                    force: false,
                    auditNote: nil,
                    actor: "test",
                    operationId: operationId
                ))
            )

            let first = await handler.handle(request)
            guard case .failure(_, let error1) = first else {
                await hold.release()
                _ = await holdTask.result
                return XCTFail("writerBusy producer must fail, got success")
            }
            // Wire name may be WriterBusy; details must carry terminal marker.
            XCTAssertTrue(
                EngramServiceErrorEnvelope.hasOperationTerminalMarker(error1.details),
                "first terminal response must include operationTerminal marker: \(String(describing: error1.details))"
            )
            let typed1 = error1.asError()
            // Marker forces commandFailed so typed reconnect helpers cannot reclassify.
            guard case .commandFailed(let name, _, _, let details) = typed1 else {
                await hold.release()
                _ = await holdTask.result
                return XCTFail("asError with terminal marker must yield commandFailed, got \(typed1)")
            }
            XCTAssertEqual(name, "WriterBusy")
            XCTAssertTrue(EngramServiceErrorEnvelope.hasOperationTerminalMarker(details))

            // Same-ID cached response is semantically identical.
            let second = await withTimeout(seconds: 2) {
                await handler.handle(request)
            }
            guard case .failure(_, let error2)? = second else {
                await hold.release()
                _ = await holdTask.result
                return XCTFail("same-ID must return cached terminal failure")
            }
            XCTAssertEqual(error2.name, error1.name)
            XCTAssertEqual(error2.message, error1.message)
            XCTAssertTrue(EngramServiceErrorEnvelope.hasOperationTerminalMarker(error2.details))
            guard case .commandFailed = error2.asError() else {
                await hold.release()
                _ = await holdTask.result
                return XCTFail("cached response asError must stay commandFailed")
            }

            await hold.release()
            _ = await holdTask.result
        }
    }

    func testCapacityExceededDoesNotCreateEntry_repro() async throws {
        try await withTemporaryHome { home in
            let paths = try makePaths()
            try migrateDatabase(at: paths.database.path)
            let gate = try ServiceWriterGate(
                databasePath: paths.database.path,
                runtimeDirectory: paths.runtime
            )
            // Cap shared registry at 2 running; pre-fill with two running ops.
            ProjectMoveBatchCancelRegistry.shared.replaceConfigForTests(
                .init(
                    maxTerminalEntries: 64,
                    maxCancelOnlyEntries: 32,
                    maxRunningEntries: 2,
                    terminalTTL: 1800,
                    cancelOnlyTTL: 60,
                    now: { Date() }
                )
            )
            _ = ProjectMoveBatchCancelRegistry.shared.beginOrJoin(
                operationId: "capacity-a",
                fingerprint: #"{"k":"a"}"#
            )
            _ = ProjectMoveBatchCancelRegistry.shared.beginOrJoin(
                operationId: "capacity-b",
                fingerprint: #"{"k":"b"}"#
            )

            let handler = EngramServiceCommandHandler(writerGate: gate)
            let src = home.appendingPathComponent(".claude/projects/cap-src", isDirectory: true)
            let dst = home.appendingPathComponent(".claude/projects/cap-dst", isDirectory: true)
            try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
            let request = EngramServiceRequestEnvelope(
                command: "projectMove",
                payload: try JSONEncoder().encode(EngramServiceProjectMoveRequest(
                    src: src.path,
                    dst: dst.path,
                    dryRun: true,
                    force: false,
                    auditNote: nil,
                    actor: "test",
                    operationId: "capacity-c"
                ))
            )
            let response = await handler.handle(request)
            guard case .failure(_, let error) = response else {
                return XCTFail("capacity must fail before detached producer")
            }
            XCTAssertEqual(error.name, "ServiceUnavailable")
            XCTAssertTrue(error.message.contains("capacity"), error.message)
            XCTAssertFalse(
                ProjectMoveBatchCancelRegistry.shared.hasEntryForTests("capacity-c"),
                "rejected id must not create running/terminal entry"
            )
            XCTAssertFalse(
                EngramServiceErrorEnvelope.hasOperationTerminalMarker(error.details),
                "admission rejection is not a cached terminal"
            )
        }
    }

    // MARK: - Unsafe batch via real handler encode + same-ID reconnect

    func testHandlerUnsafeBatchCachesCancelUnsafeFieldsOnReconnect_repro() async throws {
        try await withTemporaryHome { home in
            let paths = try makePaths()
            try migrateDatabase(at: paths.database.path)
            let gate = try ServiceWriterGate(
                databasePath: paths.database.path,
                runtimeDirectory: paths.runtime
            )
            // HOME-confined paths so real handler preflight passes and reaches batchRunOverride.
            let src = home.appendingPathComponent(".claude/projects/batch-src", isDirectory: true)
            let dst = home.appendingPathComponent(".claude/projects/batch-dst", isDirectory: true)
            try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)

            let operationId = "batch-unsafe-op"
            let op = BatchOperation(src: src.path, dst: dst.path)
            let unsafeResult = BatchResult(
                completed: [],
                failed: [
                    BatchOperationFailure(
                        operation: op,
                        error: "project-move: cancelled before commit but compensation was incomplete — rollback"
                    ),
                ],
                skipped: [],
                remaining: [op],
                cancelled: true,
                cancelUnsafe: true,
                cancelErrorName: "ProjectMoveCancelCompensationFailedError",
                cancelErrorMessage:
                    "project-move: cancelled before commit but compensation was incomplete — rollback"
            )
            let hooks = ProjectMoveLongOpHooks(
                onProducerHoldsGate: nil,
                stallWhileHoldingGate: nil,
                batchRunOverride: { _, _, _ in unsafeResult }
            )
            let handler = EngramServiceCommandHandler(writerGate: gate, longOpHooks: hooks)

            let yaml = """
            {"version":1,"operations":[{"src":"\(src.path)","dst":"\(dst.path)"}]}
            """
            let request = EngramServiceRequestEnvelope(
                command: "projectMoveBatch",
                payload: try JSONEncoder().encode(EngramServiceProjectMoveBatchRequest(
                    yaml: yaml,
                    dryRun: false,
                    force: false,
                    actor: "test",
                    operationId: operationId
                ))
            )

            let first = await handler.handle(request)
            let firstData = try assertSuccessData(first)
            let firstJSON = try JSONDecoder().decode(EngramServiceJSONValue.self, from: firstData)
            assertCancelUnsafe(firstJSON)

            // Same-ID reconnect must return cached encoded payload (handler path).
            let second = await withTimeout(seconds: 2) {
                await handler.handle(request)
            }
            let secondData = try assertSuccessData(
                try XCTUnwrap(second, "reconnect must complete within timeout")
            )
            let secondJSON = try JSONDecoder().decode(EngramServiceJSONValue.self, from: secondData)
            assertCancelUnsafe(secondJSON)
        }
    }

    // MARK: - Helpers

    private func assertSuccessData(
        _ response: EngramServiceResponseEnvelope
    ) throws -> Data {
        guard case .success(_, let data, _) = response else {
            if case .failure(_, let error) = response {
                XCTFail("expected success, got \(error.name): \(error.message)")
            }
            throw NSError(domain: "test", code: 1)
        }
        return data
    }

    private func assertCancelUnsafe(_ value: EngramServiceJSONValue) {
        guard case .object(let root) = value else {
            return XCTFail("expected object")
        }
        guard case .bool(true)? = root["cancel_unsafe"] else {
            return XCTFail("cancel_unsafe missing")
        }
        guard case .string(let name)? = root["cancel_error_name"] else {
            return XCTFail("cancel_error_name missing")
        }
        XCTAssertEqual(name, "ProjectMoveCancelCompensationFailedError")
        guard case .string(let message)? = root["cancel_error_message"] else {
            return XCTFail("cancel_error_message missing")
        }
        XCTAssertTrue(message.contains("compensation was incomplete"))
    }

    private func withTemporaryHome<T>(_ body: (URL) async throws -> T) async rethrows -> T {
        let home = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("engram-longop-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let homeScope = ServiceCoreTestHomeScope(home: home)
        defer {
            homeScope.restore()
            try? FileManager.default.removeItem(at: home)
        }
        return try await body(home)
    }

    private func makePaths() throws -> (runtime: URL, socket: URL, database: URL) {
        let root = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("engram-longop-ipc-\(UUID().uuidString.prefix(8))", isDirectory: true)
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

    private func migrateDatabase(at path: String) throws {
        let writer = try EngramDatabaseWriter(path: path)
        try writer.migrate()
    }

    /// Hard one-shot race: returns as soon as body or timeout wins; never waits for the loser.
    private func withTimeout<T: Sendable>(
        seconds: Double,
        _ body: @escaping @Sendable () async -> T
    ) async -> T? {
        await HardTimeout.race(seconds: seconds, operation: body)
    }

    func testWithTimeoutReturnsEvenWhenChildIgnoresCancellation_repro() async {
        let start = Date()
        let result: Int? = await withTimeout(seconds: 0.15) {
            // Cancellation-insensitive finite wait: Task.cancel must not hot-spin.
            // Dispatch asyncAfter ignores cooperative cancellation; loser ends ~0.75s later.
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.75) {
                    cont.resume()
                }
            }
            return 1
        }
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertNil(result, "timeout must win")
        XCTAssertLessThan(elapsed, 0.5, "helper must not await the hanging child")
    }

    private func waitUntil(
        timeout: Double,
        _ predicate: @escaping @Sendable () async -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await predicate() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return await predicate()
    }
}

/// Exactly-once one-shot race used by long-op IPC tests.
enum HardTimeout {
    static func race<T: Sendable>(
        seconds: Double,
        operation: @escaping @Sendable () async -> T
    ) async -> T? {
        await withCheckedContinuation { (cont: CheckedContinuation<T?, Never>) in
            let box = OnceResumeBox<T?>()
            let op = Task {
                let value = await operation()
                if box.complete(with: value) {
                    cont.resume(returning: value)
                }
            }
            Task {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                if box.complete(with: nil) {
                    op.cancel()
                    cont.resume(returning: nil)
                }
            }
        }
    }
}

private final class OnceResumeBox<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func complete(with value: T) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}

private actor StallBox {
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func waitUntilReleased() async {
        if released { return }
        await withCheckedContinuation { cont in
            waiters.append(cont)
        }
    }

    func release() {
        released = true
        let pending = waiters
        waiters = []
        for w in pending { w.resume() }
    }
}

private final class WriteEnteredFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = false
    var value: Bool {
        lock.lock(); defer { lock.unlock() }
        return _value
    }
    func mark() {
        lock.lock(); _value = true; lock.unlock()
    }
}
