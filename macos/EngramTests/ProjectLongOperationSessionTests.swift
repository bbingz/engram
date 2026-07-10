import XCTest
@testable import Engram

final class ProjectLongOperationSessionTests: XCTestCase {
    func testKeepsOperationIdAcrossTransientFailures_repro() async throws {
        var session = ProjectLongOperationSession(maxTransientRetries: 3)
        let id = session.beginOrReuseOperationId(mint: { "stable-id" })
        XCTAssertEqual(id, "stable-id")
        XCTAssertTrue(session.blocksDuplicateSubmit)

        var attempts = 0
        do {
            _ = try await ProjectLongOperationRunner.execute(
                session: &session,
                isReconnectable: { _ in true }
            ) { operationId in
                XCTAssertEqual(operationId, "stable-id")
                attempts += 1
                if attempts < 3 {
                    throw EngramServiceError.transportClosed(message: "timeout")
                }
                return "ok"
            }
        } catch {
            XCTFail("should succeed after transient retries: \(error)")
        }
        XCTAssertEqual(attempts, 3)
        XCTAssertNil(session.operationId, "terminal success clears id")
        XCTAssertFalse(session.blocksDuplicateSubmit)
    }

    func testExhaustedRetriesRetainIdForResume_repro() async {
        var session = ProjectLongOperationSession(maxTransientRetries: 1)
        _ = session.beginOrReuseOperationId(mint: { "keep-me" })
        do {
            _ = try await ProjectLongOperationRunner.execute(
                session: &session,
                isReconnectable: { _ in true }
            ) { _ in
                throw EngramServiceError.serviceUnavailable(message: "timeout")
            }
            XCTFail("expected throw")
        } catch {
            // exhausted
        }
        XCTAssertEqual(session.operationId, "keep-me")
        XCTAssertTrue(session.blocksDuplicateSubmit)
        XCTAssertEqual(session.prepareResume(), "keep-me")
    }

    func testNonReconnectableClearsId_repro() async {
        var session = ProjectLongOperationSession()
        _ = session.beginOrReuseOperationId(mint: { "gone" })
        do {
            _ = try await ProjectLongOperationRunner.execute(
                session: &session,
                isReconnectable: projectMoveIsReconnectableError
            ) { _ in
                throw EngramServiceError.invalidRequest(message: "bad path")
            }
            XCTFail("expected throw")
        } catch {
            // ok
        }
        XCTAssertNil(session.operationId)
        XCTAssertFalse(session.blocksDuplicateSubmit)
    }

    func testCancelledBeforeCommitWordingIsPrecise_repro() {
        let clean = projectMoveCancelledBeforeCommitMessage(kind: "Rename")
        XCTAssertTrue(clean.contains("cancelled before commit"))
        XCTAssertTrue(clean.contains("Safe to retry"))
        let dirty = projectMoveCancelCompensationFailedMessage("rollback: 1 file failed")
        XCTAssertTrue(dirty.contains("compensation was incomplete") || dirty.contains("rollback"))
        XCTAssertFalse(dirty.contains("Safe to retry"))
        XCTAssertFalse(dirty.contains("no files or index rows were committed"))
    }

    func testReconnectableHelperTreatsTransportAndCancellation_repro() {
        XCTAssertTrue(
            projectMoveIsReconnectableError(
                EngramServiceError.transportClosed(message: "socket closed")
            )
        )
        XCTAssertTrue(projectMoveIsReconnectableError(CancellationError()))
        XCTAssertFalse(
            projectMoveIsReconnectableError(
                EngramServiceError.invalidRequest(message: "bad")
            )
        )
        XCTAssertTrue(
            projectMoveIsCancelCompensationFailure(
                EngramServiceError.commandFailed(
                    name: "ProjectMoveCancelCompensationFailedError",
                    message: "incomplete",
                    retryPolicy: "never",
                    details: ["state": .string("cancelled_compensation_failed")]
                )
            )
        )
    }
}
