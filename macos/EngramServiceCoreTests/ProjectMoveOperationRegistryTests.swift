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

    func testEndItemCommitWindowReopensCancelForNextBatchItem_repro() {
        let reg = makeRegistry()
        let id = "batch-window"
        _ = reg.beginOrJoin(operationId: id, fingerprint: #"{"k":"1"}"#)
        XCTAssertTrue(reg.beginCommitIfNotCancelled(operationId: id))
        reg.requestCancel(operationId: id)
        XCTAssertFalse(reg.shouldStop(operationId: id), "cancel ignored during commit window")
        reg.endItemCommitWindow(operationId: id)
        XCTAssertTrue(
            reg.shouldStop(operationId: id),
            "after item settles, queued cancel must stop before next item"
        )
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

    func testLRUUsesTouchedAtNotTerminalAt_repro() {
        var clock = Date(timeIntervalSince1970: 10_000)
        let reg = makeRegistry(maxTerminal: 2, terminalTTL: 10_000, now: { clock })
        _ = reg.beginOrJoin(operationId: "old", fingerprint: #"{"k":"old"}"#)
        reg.complete(operationId: "old", payload: Data("old".utf8))
        clock = clock.addingTimeInterval(1)
        _ = reg.beginOrJoin(operationId: "mid", fingerprint: #"{"k":"mid"}"#)
        reg.complete(operationId: "mid", payload: Data("mid".utf8))
        clock = clock.addingTimeInterval(1)
        // Access old → refreshes touchedAt so mid becomes colder.
        switch reg.beginOrJoin(operationId: "old", fingerprint: #"{"k":"old"}"#) {
        case .completed:
            break
        default:
            XCTFail("old terminal must hit")
        }
        clock = clock.addingTimeInterval(1)
        _ = reg.beginOrJoin(operationId: "new", fingerprint: #"{"k":"new"}"#)
        reg.complete(operationId: "new", payload: Data("new".utf8))
        // Cap 2: mid (least recently touched) should be gone; old and new remain.
        switch reg.beginOrJoin(operationId: "old", fingerprint: #"{"k":"old"}"#) {
        case .completed(.success(let data)):
            XCTAssertEqual(data, Data("old".utf8), "accessed old terminal must survive LRU")
        default:
            XCTFail("old must survive")
        }
        switch reg.beginOrJoin(operationId: "mid", fingerprint: #"{"k":"mid"}"#) {
        case .proceed:
            break // evicted
        default:
            XCTFail("unused mid terminal should be evicted under LRU")
        }
    }

    func testTerminalTTLEvictionPreservesRunning_repro() {
        var clock = Date(timeIntervalSince1970: 1_000)
        let reg = makeRegistry(maxTerminal: 10, terminalTTL: 10, now: { clock })
        _ = reg.beginOrJoin(operationId: "done", fingerprint: #"{"k":"1"}"#)
        reg.complete(operationId: "done", payload: Data("x".utf8))
        _ = reg.beginOrJoin(operationId: "run", fingerprint: #"{"k":"2"}"#)
        clock = clock.addingTimeInterval(11)
        _ = reg.beginOrJoin(operationId: "fresh", fingerprint: #"{"k":"3"}"#)
        XCTAssertTrue(reg.isRunningForTests("run"))
        switch reg.beginOrJoin(operationId: "done", fingerprint: #"{"k":"1"}"#) {
        case .proceed:
            break
        default:
            XCTFail("TTL-expired terminal must not remain as completed")
        }
    }

    func testParkedWaiterDetachDoesNotCancelAndReconnectSeesTerminal_repro() async throws {
        let reg = makeRegistry()
        let id = "parked-waiter"
        _ = reg.beginOrJoin(operationId: id, fingerprint: #"{"k":"1"}"#)

        let parked = Task {
            try await reg.waitForTerminal(operationId: id)
        }
        try await Task.sleep(nanoseconds: 30_000_000)
        parked.cancel()
        do {
            _ = try await parked.value
            XCTFail("must throw")
        } catch is CancellationError {
            // ok
        }
        XCTAssertFalse(reg.shouldStop(operationId: id))
        let payload = Data("terminal".utf8)
        reg.complete(operationId: id, payload: payload)
        switch reg.beginOrJoin(operationId: id, fingerprint: #"{"k":"1"}"#) {
        case .completed(.success(let data)):
            XCTAssertEqual(data, payload)
        default:
            XCTFail("reconnect must see terminal")
        }
    }

    func testWaiterImmediateCancelRace_repro() async throws {
        let reg = makeRegistry()
        let id = "waiter-race"
        _ = reg.beginOrJoin(operationId: id, fingerprint: #"{"k":"1"}"#)
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
        XCTAssertFalse(reg.shouldStop(operationId: id))
        reg.complete(operationId: id, payload: Data("done".utf8))
        switch reg.beginOrJoin(operationId: id, fingerprint: #"{"k":"1"}"#) {
        case .completed(.success):
            break
        default:
            XCTFail("producer terminal remains after waiter detach")
        }
    }

    func testTerminalBeforeCancelIsNoOpExactlyOnce_repro() async throws {
        let reg = makeRegistry()
        let id = "term-before-cancel"
        _ = reg.beginOrJoin(operationId: id, fingerprint: #"{"k":"1"}"#)
        reg.complete(operationId: id, payload: Data("done".utf8))
        // Wait after terminal: returns immediately.
        let terminal = try await reg.waitForTerminal(operationId: id)
        guard case .success(let data) = terminal else {
            return XCTFail("expected success")
        }
        XCTAssertEqual(data, Data("done".utf8))
        // Residual cancel must not leave unbounded waiter state.
        XCTAssertEqual(reg.waiterStateCountForTests(), 0)
    }

    func testUnknownCancelReservationsAreBounded_repro() {
        var clock = Date(timeIntervalSince1970: 10_000)
        let reg = makeRegistry(maxCancelOnly: 5, cancelOnlyTTL: 100, now: { clock })
        for i in 0..<20 {
            reg.requestCancel(operationId: "unknown-\(i)")
        }
        XCTAssertLessThanOrEqual(reg.cancelOnlyCountForTests(), 5)
    }
}
