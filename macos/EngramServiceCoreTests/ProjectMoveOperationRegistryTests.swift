import XCTest
@testable import EngramServiceCore

/// Wave 8 long-ops rescue: atomic commit boundary, disconnect ≠ cancel, TTL,
/// fingerprints, structured failure identity, terminal preflight resolution.
final class ProjectMoveOperationRegistryTests: XCTestCase {
    private func makeRegistry(
        maxTerminal: Int = 64,
        ttl: TimeInterval = 1800,
        now: @escaping @Sendable () -> Date = { Date() }
    ) -> ProjectMoveBatchCancelRegistry {
        let reg = ProjectMoveBatchCancelRegistry(
            config: .init(maxTerminalEntries: maxTerminal, terminalTTL: ttl, now: now)
        )
        return reg
    }

    func testBeginCommitIfNotCancelled_cancelWins_repro() {
        let reg = makeRegistry()
        let id = "race-cancel"
        _ = reg.beginOrJoin(operationId: id, fingerprint: #"{"kind":"move"}"#)
        reg.requestCancel(operationId: id)
        XCTAssertFalse(
            reg.beginCommitIfNotCancelled(operationId: id),
            "cancel before commit transition must win"
        )
        XCTAssertTrue(reg.shouldStop(operationId: id))
    }

    func testBeginCommitIfNotCancelled_commitWins_laterCancelIgnored_repro() {
        let reg = makeRegistry()
        let id = "race-commit"
        _ = reg.beginOrJoin(operationId: id, fingerprint: #"{"kind":"move"}"#)
        XCTAssertTrue(reg.beginCommitIfNotCancelled(operationId: id))
        reg.requestCancel(operationId: id)
        XCTAssertFalse(
            reg.shouldStop(operationId: id),
            "explicit cancel after commit transition must be ignored"
        )
        XCTAssertTrue(reg.isPastCommit(operationId: id))
    }

    func testWaiterDetachesOnParentCancelWithoutRequestingCancel_repro() async throws {
        let reg = makeRegistry()
        let id = "detach-waiter"
        _ = reg.beginOrJoin(operationId: id, fingerprint: #"{"kind":"move"}"#)

        let waiter = Task {
            try await reg.waitForTerminal(operationId: id)
        }
        // Let waiter park.
        try await Task.sleep(nanoseconds: 30_000_000)
        waiter.cancel()
        do {
            _ = try await waiter.value
            XCTFail("cancelled waiter must throw")
        } catch is CancellationError {
            // ok
        }
        // Work still running; cancel was NOT requested by detach.
        XCTAssertFalse(reg.shouldStop(operationId: id))
        XCTAssertTrue(reg.isRunningForTests(id))

        let payload = Data("ok".utf8)
        reg.complete(operationId: id, payload: payload)
        // Terminal still available for reconnect join.
        switch reg.beginOrJoin(operationId: id, fingerprint: #"{"kind":"move"}"#) {
        case .completed(.success(let data)):
            XCTAssertEqual(data, payload)
        default:
            XCTFail("reconnect must see completed payload")
        }
    }

    func testExplicitCancelStillStopsBeforeCommit_repro() {
        let reg = makeRegistry()
        let id = "explicit-cancel"
        _ = reg.beginOrJoin(operationId: id, fingerprint: #"{"k":"1"}"#)
        reg.requestCancel(operationId: id)
        XCTAssertTrue(reg.shouldStop(operationId: id))
    }

    func testPreflightFailureTerminalBlocksForeverJoin_repro() async throws {
        let reg = makeRegistry()
        let id = "preflight-fail"
        _ = reg.beginOrJoin(operationId: id, fingerprint: #"{"kind":"move"}"#)
        reg.completeWithFailure(
            operationId: id,
            failure: .init(
                name: "InvalidRequest",
                message: "path escapes home",
                retryPolicy: "never"
            )
        )
        switch reg.beginOrJoin(operationId: id, fingerprint: #"{"kind":"move"}"#) {
        case .completed(.failure(let f)):
            XCTAssertEqual(f.name, "InvalidRequest")
            XCTAssertEqual(f.message, "path escapes home")
            XCTAssertEqual(f.retryPolicy, "never")
        default:
            XCTFail("same-id retry must return terminal failure, not join forever")
        }
    }

    func testStructuredFailureIdentityPreserved_repro() {
        let reg = makeRegistry()
        let id = "struct-fail"
        _ = reg.beginOrJoin(operationId: id, fingerprint: #"{"kind":"undo"}"#)
        let failure = ProjectMoveBatchCancelRegistry.CachedFailure(
            name: "DirCollisionError",
            message: "target exists",
            retryPolicy: "never",
            detailsJSON: #"{"state":"failed"}"#
        )
        reg.completeWithFailure(operationId: id, failure: failure)
        switch reg.beginOrJoin(operationId: id, fingerprint: #"{"kind":"undo"}"#) {
        case .completed(.failure(let f)):
            XCTAssertEqual(f, failure)
        default:
            XCTFail("structured failure must round-trip")
        }
    }

    func testFingerprintCollisionSafeForPipeInPath_repro() {
        let a = ProjectMoveOperationFingerprint.encode([
            "kind": "move",
            "src": "/tmp/a|b",
            "dst": "/tmp/c",
            "actor": "app",
        ])
        let b = ProjectMoveOperationFingerprint.encode([
            "kind": "move",
            "src": "/tmp/a",
            "dst": "b|/tmp/c",
            "actor": "app",
        ])
        XCTAssertNotEqual(a, b, "pipe characters inside paths must not collide")
    }

    func testFingerprintIncludesActorDifference_repro() {
        let app = ProjectMoveOperationFingerprint.encode([
            "kind": "move", "src": "/a", "dst": "/b", "actor": "app",
        ])
        let mcp = ProjectMoveOperationFingerprint.encode([
            "kind": "move", "src": "/a", "dst": "/b", "actor": "mcp",
        ])
        XCTAssertNotEqual(app, mcp)
        let reg = makeRegistry()
        _ = reg.beginOrJoin(operationId: "fp-actor", fingerprint: app)
        switch reg.beginOrJoin(operationId: "fp-actor", fingerprint: mcp) {
        case .fingerprintConflict:
            break
        default:
            XCTFail("actor difference must conflict")
        }
    }

    func testTTLEvictsTerminalButPreservesRunning_repro() {
        var clock = Date(timeIntervalSince1970: 1_000)
        let reg = makeRegistry(maxTerminal: 10, ttl: 10, now: { clock })
        _ = reg.beginOrJoin(operationId: "done", fingerprint: #"{"k":"1"}"#)
        reg.complete(operationId: "done", payload: Data("x".utf8))
        _ = reg.beginOrJoin(operationId: "run", fingerprint: #"{"k":"2"}"#)
        XCTAssertEqual(reg.entryCountForTests(), 2)

        clock = clock.addingTimeInterval(11)
        // Trigger prune via another begin.
        _ = reg.beginOrJoin(operationId: "fresh", fingerprint: #"{"k":"3"}"#)
        XCTAssertTrue(reg.isRunningForTests("run"), "running must never be TTL-evicted")
        // Terminal "done" should be gone; running + fresh remain.
        XCTAssertLessThanOrEqual(reg.entryCountForTests(), 2)
        switch reg.beginOrJoin(operationId: "done", fingerprint: #"{"k":"1"}"#) {
        case .proceed:
            break // expired terminal treated as new begin
        default:
            // join/completed would mean it was not evicted
            XCTFail("expired terminal should not remain as completed")
        }
    }

    func testLRUCapPreservesWaitersAndRunning_repro() async throws {
        var clock = Date(timeIntervalSince1970: 5_000)
        let reg = makeRegistry(maxTerminal: 2, ttl: 10_000, now: { clock })
        for i in 0..<3 {
            let id = "t\(i)"
            _ = reg.beginOrJoin(operationId: id, fingerprint: #"{"i":"\#(i)"}"#)
            reg.complete(operationId: id, payload: Data("\(i)".utf8))
            clock = clock.addingTimeInterval(1)
        }
        // Force prune
        _ = reg.beginOrJoin(operationId: "runner", fingerprint: #"{"k":"r"}"#)
        XCTAssertTrue(reg.isRunningForTests("runner"))
        // At most 2 terminals + 1 running
        XCTAssertLessThanOrEqual(reg.entryCountForTests(), 3)
    }
}
