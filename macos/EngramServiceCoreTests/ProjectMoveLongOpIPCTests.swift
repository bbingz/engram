import XCTest
import GRDB
import Foundation
import EngramCoreWrite
@testable import EngramServiceCore

/// Behavioral long-op IPC/handler tests (hard-gate regression coverage).
final class ProjectMoveLongOpIPCTests: XCTestCase {
    override func tearDown() {
        ProjectMoveLongOpTestHooks.reset()
        ProjectMoveBatchCancelRegistry.shared.remove(operationId: "preflight-op")
        ProjectMoveBatchCancelRegistry.shared.remove(operationId: "preflight-conflict")
        ProjectMoveBatchCancelRegistry.shared.remove(operationId: "gate-hold-op")
        super.tearDown()
    }

    // MARK: - 1) REAL handler preflight terminalization

    func testHandlerPreflightFailureIsTerminalForSameOperationId_repro() async throws {
        try await withTemporaryHome { _ in
            let paths = try makePaths()
            try migrateDatabase(at: paths.database.path)
            let gate = try ServiceWriterGate(
                databasePath: paths.database.path,
                runtimeDirectory: paths.runtime
            )
            let handler = EngramServiceCommandHandler(writerGate: gate)
            let operationId = "preflight-op"

            let invalid = EngramServiceProjectMoveRequest(
                src: "/etc/passwd-dir",
                dst: "/tmp/elsewhere",
                dryRun: true,
                force: true,
                auditNote: nil,
                actor: "test",
                operationId: operationId
            )
            let request = EngramServiceRequestEnvelope(
                command: "projectMove",
                payload: try JSONEncoder().encode(invalid)
            )

            let first = await handler.handle(request)
            guard case .failure(_, let error1) = first else {
                return XCTFail("first invalid projectMove must fail confinement")
            }
            XCTAssertEqual(error1.name, "InvalidRequest")
            XCTAssertTrue(error1.message.contains("outside the home directory"), error1.message)

            // Resend exact same request — must return cached terminal promptly (no hang/join).
            let t0 = Date()
            let second = await handler.handle(request)
            XCTAssertLessThan(Date().timeIntervalSince(t0), 2, "cached terminal must return promptly")
            guard case .failure(_, let error2) = second else {
                return XCTFail("second identical request must return cached failure")
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

            // Same operationId, different src/dst/actor → fingerprint conflict.
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
                return XCTFail("conflicting fingerprint must fail, not join/succeed")
            }
            XCTAssertEqual(error.name, "InvalidRequest")
            XCTAssertTrue(
                error.message.contains("operation_id already used"),
                error.message
            )
        }
    }

    // MARK: - 2) Producer gate ownership after waiter detach

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
                // Unbounded wait so the unrelated write parks behind the holder.
                queueTimeoutNanoseconds: 0
            )
            let handler = EngramServiceCommandHandler(writerGate: gate)
            let operationId = "gate-hold-op"

            let producerHoldsGate = expectation(description: "producer holds gate")
            let stallBox = StallBox()
            let writeEntered = WriteEnteredFlag()

            ProjectMoveLongOpTestHooks.onProducerHoldsGate = {
                producerHoldsGate.fulfill()
            }
            ProjectMoveLongOpTestHooks.stallWhileHoldingGate = {
                await stallBox.waitUntilReleased()
            }
            defer { ProjectMoveLongOpTestHooks.reset() }

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

            // Client waiter task — cancelled while producer still holds gate.
            let clientTask = Task {
                await handler.handle(request)
            }

            await fulfillment(of: [producerHoldsGate], timeout: 5)

            // Detach waiter only — must NOT request operation cancel.
            clientTask.cancel()
            try await Task.sleep(nanoseconds: 50_000_000)
            XCTAssertFalse(
                ProjectMoveBatchCancelRegistry.shared.shouldStop(operationId: operationId),
                "waiter detach must not request cooperative cancel"
            )

            // Unrelated write must stay serialized behind the still-held gate.
            let writeFinished = expectation(description: "unrelated write finished")
            let writeTask = Task {
                _ = try await gate.performWriteCommand(name: "setFavorite") { _ in
                    writeEntered.mark()
                    return "done"
                }
                writeFinished.fulfill()
            }

            try await Task.sleep(nanoseconds: 300_000_000)
            XCTAssertFalse(
                writeEntered.value,
                "unrelated write must not enter gate body while producer still holds it"
            )

            // Release producer stall → dry-run completes → gate free.
            await stallBox.release()

            await fulfillment(of: [writeFinished], timeout: 5)
            XCTAssertTrue(writeEntered.value)
            _ = await clientTask.result
            _ = await writeTask.result

            // Reconnect sees terminal.
            let reconnect = await handler.handle(request)
            switch reconnect {
            case .success:
                break
            case .failure(_, let error):
                XCTAssertFalse(error.name.isEmpty)
            }
        }
    }

    // MARK: - Helpers

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
}

/// Actor gate used only by long-op producer stall tests.
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
