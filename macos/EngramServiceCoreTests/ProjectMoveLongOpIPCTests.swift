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
        ] {
            ProjectMoveBatchCancelRegistry.shared.remove(operationId: id)
        }
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
            try await Task.sleep(nanoseconds: 20_000_000)
            XCTAssertFalse(
                ProjectMoveBatchCancelRegistry.shared.shouldStop(operationId: operationId)
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
            _ = await clientTask.result
            _ = await writeTask.result
        }
    }

    // MARK: - Unsafe batch via real handler encode + same-ID reconnect

    func testHandlerUnsafeBatchCachesCancelUnsafeFieldsOnReconnect_repro() async throws {
        try await withTemporaryHome { _ in
            let paths = try makePaths()
            try migrateDatabase(at: paths.database.path)
            let gate = try ServiceWriterGate(
                databasePath: paths.database.path,
                runtimeDirectory: paths.runtime
            )
            let operationId = "batch-unsafe-op"
            let unsafeResult = BatchResult(
                completed: [],
                failed: [
                    BatchOperationFailure(
                        operation: BatchOperation(src: "/a", dst: "/b"),
                        error: "project-move: cancelled before commit but compensation was incomplete — rollback"
                    ),
                ],
                skipped: [],
                remaining: [BatchOperation(src: "/a", dst: "/b")],
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

            let yaml = #"{"version":1,"operations":[{"src":"/a","dst":"/b"}]}"#
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

            // Same-ID reconnect must return cached encoded payload (handler path, not manual registry).
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

    private func withTimeout<T: Sendable>(
        seconds: Double,
        _ body: @escaping @Sendable () async -> T
    ) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask { await body() }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                return nil
            }
            let first = await group.next()!
            group.cancelAll()
            return first
        }
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
