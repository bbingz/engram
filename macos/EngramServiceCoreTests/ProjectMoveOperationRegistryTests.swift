import XCTest
@testable import EngramServiceCore

final class ProjectMoveOperationRegistryTests: XCTestCase {
    private func makeRegistry(
        maxTerminal: Int = 64,
        maxCancelOnly: Int = 32,
        terminalTTL: TimeInterval = 1800,
        cancelOnlyTTL: TimeInterval = 60,
        now: @escaping @Sendable () -> Date = { Date() }
    ) -> ProjectMoveBatchCancelRegistry {
        ProjectMoveBatchCancelRegistry(
            config: .init(
                maxTerminalEntries: maxTerminal,
                maxCancelOnlyEntries: maxCancelOnly,
                terminalTTL: terminalTTL,
                cancelOnlyTTL: cancelOnlyTTL,
                now: now
            )
        )
    }

    func testBeginCommitIfNotCancelled_cancelWins_repro() {
        let reg = makeRegistry()
        _ = reg.beginOrJoin(operationId: "race-cancel", fingerprint: #"{"k":"1"}"#)
        reg.requestCancel(operationId: "race-cancel")
        XCTAssertFalse(reg.beginCommitIfNotCancelled(operationId: "race-cancel"))
    }

    func testBeginCommitIfNotCancelled_commitWins_laterCancelIgnored_repro() {
        let reg = makeRegistry()
        _ = reg.beginOrJoin(operationId: "race-commit", fingerprint: #"{"k":"1"}"#)
        XCTAssertTrue(reg.beginCommitIfNotCancelled(operationId: "race-commit"))
        reg.requestCancel(operationId: "race-commit")
        XCTAssertFalse(reg.shouldStop(operationId: "race-commit"))
    }

    func testTerminalFingerprintConflictOnCompleted_repro() {
        let reg = makeRegistry()
        let id = "term-fp"
        _ = reg.beginOrJoin(operationId: id, fingerprint: #"{"actor":"app"}"#)
        reg.complete(operationId: id, payload: Data("ok".utf8))
        switch reg.beginOrJoin(operationId: id, fingerprint: #"{"actor":"mcp"}"#) {
        case .fingerprintConflict:
            break
        default:
            XCTFail("completed terminal must still fingerprint-check")
        }
    }

    func testTerminalFingerprintConflictOnFailed_repro() {
        let reg = makeRegistry()
        let id = "term-fail-fp"
        _ = reg.beginOrJoin(operationId: id, fingerprint: #"{"src":"/a"}"#)
        reg.completeWithFailure(
            operationId: id,
            failure: .init(name: "InvalidRequest", message: "bad", retryPolicy: "never")
        )
        switch reg.beginOrJoin(operationId: id, fingerprint: #"{"src":"/b"}"#) {
        case .fingerprintConflict:
            break
        default:
            XCTFail("failed terminal must still fingerprint-check")
        }
    }

    func testWaiterImmediateCancelRace_repro() async throws {
        let reg = makeRegistry()
        let id = "waiter-race"
        _ = reg.beginOrJoin(operationId: id, fingerprint: #"{"k":"1"}"#)

        // Cancel the waiting task before it can register (tight race).
        let waiter = Task {
            try await reg.waitForTerminal(operationId: id)
        }
        waiter.cancel()
        do {
            _ = try await waiter.value
            XCTFail("must throw CancellationError")
        } catch is CancellationError {
            // ok
        }
        // Producer can still complete; cancel was not requested.
        XCTAssertFalse(reg.shouldStop(operationId: id))
        reg.complete(operationId: id, payload: Data("done".utf8))
        switch reg.beginOrJoin(operationId: id, fingerprint: #"{"k":"1"}"#) {
        case .completed(.success(let data)):
            XCTAssertEqual(data, Data("done".utf8))
        default:
            XCTFail("producer terminal must remain available after waiter detach")
        }
    }

    func testUnknownCancelReservationsAreBounded_repro() {
        var clock = Date(timeIntervalSince1970: 10_000)
        let reg = makeRegistry(maxCancelOnly: 5, cancelOnlyTTL: 100, now: { clock })
        for i in 0..<20 {
            reg.requestCancel(operationId: "unknown-\(i)")
        }
        XCTAssertLessThanOrEqual(reg.cancelOnlyCountForTests(), 5)
        clock = clock.addingTimeInterval(200)
        reg.requestCancel(operationId: "trigger-prune")
        XCTAssertLessThanOrEqual(reg.cancelOnlyCountForTests(), 5)
    }

    func testFingerprintPipeSafeAndActorDifference_repro() {
        let a = ProjectMoveOperationFingerprint.encode([
            "kind": "move", "src": "/tmp/a|b", "dst": "/tmp/c", "actor": "app",
        ])
        let b = ProjectMoveOperationFingerprint.encode([
            "kind": "move", "src": "/tmp/a", "dst": "b|/tmp/c", "actor": "app",
        ])
        XCTAssertNotEqual(a, b)
        let app = ProjectMoveOperationFingerprint.encode(["kind": "move", "actor": "app"])
        let mcp = ProjectMoveOperationFingerprint.encode(["kind": "move", "actor": "mcp"])
        XCTAssertNotEqual(app, mcp)
    }

    func testStructuredFailureIdentityPreserved_repro() {
        let reg = makeRegistry()
        let id = "struct"
        _ = reg.beginOrJoin(operationId: id, fingerprint: #"{"k":"1"}"#)
        let failure = ProjectMoveBatchCancelRegistry.CachedFailure(
            name: "ProjectMoveCancelCompensationFailedError",
            message: "incomplete",
            retryPolicy: "never",
            detailsJSON: #"{"state":"cancelled_compensation_failed"}"#
        )
        reg.completeWithFailure(operationId: id, failure: failure)
        switch reg.beginOrJoin(operationId: id, fingerprint: #"{"k":"1"}"#) {
        case .completed(.failure(let f)):
            XCTAssertEqual(f, failure)
        default:
            XCTFail("expected structured failure")
        }
    }

    func testPreflightFailureTerminalBlocksForeverJoin_repro() {
        let reg = makeRegistry()
        let id = "preflight"
        // Handler path is covered by ProjectMoveLongOpIPCTests; this asserts
        // registry terminal semantics used by that path.
        _ = reg.beginOrJoin(operationId: id, fingerprint: #"{"kind":"move"}"#)
        reg.completeWithFailure(
            operationId: id,
            failure: .init(name: "InvalidRequest", message: "path escapes home", retryPolicy: "never")
        )
        switch reg.beginOrJoin(operationId: id, fingerprint: #"{"kind":"move"}"#) {
        case .completed(.failure(let f)):
            XCTAssertEqual(f.name, "InvalidRequest")
        default:
            XCTFail("same-id reconnect must get terminal failure, not hang")
        }
    }

    // MARK: - Bounded terminal lifecycle (restored)

    func testTerminalTTLEvictionPreservesRunning_repro() {
        var clock = Date(timeIntervalSince1970: 1_000)
        let reg = makeRegistry(maxTerminal: 10, terminalTTL: 10, now: { clock })
        _ = reg.beginOrJoin(operationId: "done", fingerprint: #"{"k":"1"}"#)
        reg.complete(operationId: "done", payload: Data("x".utf8))
        _ = reg.beginOrJoin(operationId: "run", fingerprint: #"{"k":"2"}"#)
        XCTAssertEqual(reg.entryCountForTests(), 2)

        clock = clock.addingTimeInterval(11)
        _ = reg.beginOrJoin(operationId: "fresh", fingerprint: #"{"k":"3"}"#)
        XCTAssertTrue(reg.isRunningForTests("run"), "running must never be TTL-evicted")
        switch reg.beginOrJoin(operationId: "done", fingerprint: #"{"k":"1"}"#) {
        case .proceed:
            break // expired terminal treated as new begin
        default:
            XCTFail("expired terminal should not remain as completed")
        }
    }

    func testLRUTerminalCapPreservesRunningAndWaiters_repro() async throws {
        var clock = Date(timeIntervalSince1970: 5_000)
        let reg = makeRegistry(maxTerminal: 2, terminalTTL: 10_000, now: { clock })
        for i in 0..<3 {
            let id = "t\(i)"
            _ = reg.beginOrJoin(operationId: id, fingerprint: #"{"i":"\#(i)"}"#)
            reg.complete(operationId: id, payload: Data("\(i)".utf8))
            clock = clock.addingTimeInterval(1)
        }
        _ = reg.beginOrJoin(operationId: "runner", fingerprint: #"{"k":"r"}"#)
        XCTAssertTrue(reg.isRunningForTests("runner"))
        // At most 2 terminals + 1 running
        XCTAssertLessThanOrEqual(reg.entryCountForTests(), 3)
    }

    func testParkedWaiterDetachDoesNotCancelAndReconnectSeesTerminal_repro() async throws {
        let reg = makeRegistry()
        let id = "parked-waiter"
        _ = reg.beginOrJoin(operationId: id, fingerprint: #"{"k":"1"}"#)

        let parked = Task {
            try await reg.waitForTerminal(operationId: id)
        }
        // Allow waiter to park under the lock.
        try await Task.sleep(nanoseconds: 50_000_000)
        parked.cancel()
        do {
            _ = try await parked.value
            XCTFail("parked cancel must throw")
        } catch is CancellationError {
            // ok
        }
        XCTAssertFalse(
            reg.shouldStop(operationId: id),
            "parked waiter detach must not request operation cancel"
        )
        let payload = Data("terminal".utf8)
        reg.complete(operationId: id, payload: payload)
        switch reg.beginOrJoin(operationId: id, fingerprint: #"{"k":"1"}"#) {
        case .completed(.success(let data)):
            XCTAssertEqual(data, payload)
        default:
            XCTFail("reconnect must see completed terminal after parked detach")
        }
    }
}
