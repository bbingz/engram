import XCTest
@testable import Engram

final class ProjectLongOperationSessionTests: XCTestCase {
    /// CRITICAL finding 1: operationId must be published before any await.
    func testPreparePublishesOperationIdBeforeAwait_repro() async {
        var session = ProjectLongOperationSession()
        XCTAssertNil(session.operationId)

        let prepared = ProjectLongOperationRunner.prepare(
            session: session,
            mint: { "published-before-await" }
        )
        // Simulate UI assigning @State before suspension.
        session = prepared.session
        XCTAssertEqual(session.operationId, "published-before-await")
        XCTAssertTrue(session.blocksDuplicateSubmit)

        // Cancel can read the published id while work is "in flight".
        let cancelTarget = session.operationId
        XCTAssertEqual(cancelTarget, "published-before-await")

        let gate = AsyncGate()
        async let executeResult = ProjectLongOperationRunner.execute(
            session: session,
            operationId: prepared.operationId,
            isReconnectable: { _ in false }
        ) { operationId in
            XCTAssertEqual(operationId, "published-before-await")
            await gate.wait()
            return "done"
        }

        // While suspended, session still holds the id for Cancel.
        XCTAssertEqual(session.operationId, "published-before-await")
        await gate.open()
        let finished = await executeResult
        session = finished.session
        XCTAssertEqual(try? finished.result.get(), "done")
        XCTAssertNil(session.operationId)
    }

    func testKeepsOperationIdAcrossTransientFailures_repro() async throws {
        var session = ProjectLongOperationSession(maxTransientRetries: 3)
        let prepared = ProjectLongOperationRunner.prepare(
            session: session,
            mint: { "stable-id" }
        )
        session = prepared.session

        var attempts = 0
        let executeResult = await ProjectLongOperationRunner.execute(
            session: session,
            operationId: prepared.operationId,
            isReconnectable: { _ in true }
        ) { operationId in
            XCTAssertEqual(operationId, "stable-id")
            attempts += 1
            if attempts < 3 {
                throw EngramServiceError.transportClosed(message: "timeout")
            }
            return "ok"
        }
        session = executeResult.session
        XCTAssertEqual(try? executeResult.result.get(), "ok")
        XCTAssertEqual(attempts, 3)
        XCTAssertNil(session.operationId)
    }

    func testExhaustedRetriesRetainIdForResume_repro() async {
        var session = ProjectLongOperationSession(maxTransientRetries: 1)
        let prepared = ProjectLongOperationRunner.prepare(
            session: session,
            mint: { "keep-me" }
        )
        session = prepared.session
        let executeResult = await ProjectLongOperationRunner.execute(
            session: session,
            operationId: prepared.operationId,
            isReconnectable: { _ in true }
        ) { _ in
            throw EngramServiceError.serviceUnavailable(message: "timeout")
        }
        session = executeResult.session
        guard case .failure = executeResult.result else {
            return XCTFail("expected failure")
        }
        XCTAssertEqual(session.operationId, "keep-me")
        XCTAssertTrue(session.blocksDuplicateSubmit)
    }

    func testNonReconnectableClearsId_repro() async {
        var session = ProjectLongOperationSession()
        let prepared = ProjectLongOperationRunner.prepare(session: session, mint: { "gone" })
        session = prepared.session
        let executeResult = await ProjectLongOperationRunner.execute(
            session: session,
            operationId: prepared.operationId,
            isReconnectable: projectMoveIsReconnectableError
        ) { _ in
            throw EngramServiceError.invalidRequest(message: "bad path")
        }
        session = executeResult.session
        XCTAssertNil(session.operationId)
    }

    func testCancelledBeforeCommitWordingIsPrecise_repro() {
        let clean = projectMoveCancelledBeforeCommitMessage(kind: "Rename")
        XCTAssertTrue(clean.contains("Safe to retry"))
        let dirty = projectMoveCancelCompensationFailedMessage("rollback failed")
        XCTAssertFalse(dirty.contains("Safe to retry"))
    }
}

/// Tiny async gate for behavioral tests that need a mid-await observation window.
private actor AsyncGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { cont in
            waiters.append(cont)
        }
    }

    func open() {
        isOpen = true
        let pending = waiters
        waiters = []
        for w in pending { w.resume() }
    }
}
