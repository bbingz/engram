import XCTest
@testable import EngramServiceCore

/// Wave 8 long-ops: cancel boundary, past-commit ignore, idempotent re-submit.
final class ProjectMoveOperationRegistryTests: XCTestCase {
    private var registry: ProjectMoveBatchCancelRegistry {
        ProjectMoveBatchCancelRegistry.shared
    }

    override func tearDown() {
        // Isolate tests — registry is process-global.
        registry.remove(operationId: "op-a")
        registry.remove(operationId: "op-b")
        registry.remove(operationId: "op-c")
        registry.remove(operationId: "op-idem")
        registry.remove(operationId: "op-join")
        super.tearDown()
    }

    func testCancelStopsOnlyBeforePastCommit_repro() {
        let id = "op-a"
        registry.remove(operationId: id)
        _ = registry.beginOrJoin(operationId: id, fingerprint: "fp")

        registry.requestCancel(operationId: id)
        XCTAssertTrue(registry.shouldStop(operationId: id))
        XCTAssertTrue(registry.isCancelled(operationId: id))

        registry.markPastCommit(operationId: id)
        XCTAssertTrue(registry.isPastCommit(operationId: id))
        XCTAssertFalse(
            registry.shouldStop(operationId: id),
            "after commit boundary, cancel must not stop the service pipeline"
        )
    }

    func testDuplicateSubmitReturnsCachedPayload_repro() throws {
        let id = "op-idem"
        registry.remove(operationId: id)
        let first = registry.beginOrJoin(operationId: id, fingerprint: "move|/a|/b")
        guard case .proceed = first else {
            return XCTFail("first begin must proceed")
        }
        let payload = Data(#"{"state":"committed"}"#.utf8)
        registry.complete(operationId: id, payload: payload)

        switch registry.beginOrJoin(operationId: id, fingerprint: "move|/a|/b") {
        case .completed(let data):
            XCTAssertEqual(data, payload)
        default:
            XCTFail("duplicate submit with same fingerprint must return completed payload")
        }
    }

    func testFingerprintConflictOnReuse_repro() {
        let id = "op-b"
        registry.remove(operationId: id)
        _ = registry.beginOrJoin(operationId: id, fingerprint: "fp-1")
        switch registry.beginOrJoin(operationId: id, fingerprint: "fp-2") {
        case .fingerprintConflict(let existing):
            XCTAssertEqual(existing, "fp-1")
        default:
            XCTFail("mismatched fingerprint must conflict")
        }
    }

    func testJoinWaitsForInFlightCompletion_repro() async throws {
        let id = "op-join"
        registry.remove(operationId: id)
        _ = registry.beginOrJoin(operationId: id, fingerprint: "fp")

        let expected = Data("done".utf8)
        async let joined: Data = {
            switch self.registry.beginOrJoin(operationId: id, fingerprint: "fp") {
            case .join(let wait):
                return try await wait()
            default:
                throw NSError(domain: "test", code: 1)
            }
        }()

        // Give the waiter a moment to park, then complete.
        try await Task.sleep(nanoseconds: 50_000_000)
        registry.complete(operationId: id, payload: expected)
        let got = try await joined
        XCTAssertEqual(got, expected)
    }

    func testRequestCancelBeforeBeginStillStops_repro() {
        let id = "op-c"
        registry.remove(operationId: id)
        registry.requestCancel(operationId: id)
        // Cancel reserved the entry; begin adopts fingerprint and should still stop.
        _ = registry.beginOrJoin(operationId: id, fingerprint: "fp")
        XCTAssertTrue(registry.shouldStop(operationId: id))
    }
}
