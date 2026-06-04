import XCTest
@testable import Engram

/// OBS-O2 regression coverage: the shared `EngramServiceStatusStore.apply(event:)`
/// has no `index_error` branch (falls to `default: break`), so indexing failures
/// vanished. `AppDelegate.applyServiceEvent` routes them into a degraded status,
/// and a subsequent successful index clears it.
@MainActor
final class ServiceEventRoutingTests: XCTestCase {
    private var appSource: String {
        get throws {
            var directory = URL(fileURLWithPath: #filePath)
            while directory.lastPathComponent != "macos" {
                directory.deleteLastPathComponent()
            }
            return try String(contentsOf: directory.appendingPathComponent("Engram/App.swift"), encoding: .utf8)
        }
    }

    private func decode(_ json: String) throws -> EngramServiceEvent {
        try JSONDecoder().decode(EngramServiceEvent.self, from: Data(json.utf8))
    }

    func testServiceStatusObservationUsesDetachedEventPump() throws {
        let source = try appSource
        let start = try XCTUnwrap(source.range(of: "private func startServiceStatusObservation()"))
        let end = try XCTUnwrap(source.range(of: "/// OBS-O2:"))
        let body = String(source[start.lowerBound..<end.lowerBound])

        XCTAssertTrue(body.contains("serviceStatusTask = Task.detached"))
        XCTAssertTrue(body.contains("await MainActor.run"))
        XCTAssertFalse(
            body.contains("serviceStatusTask = Task {"),
            "service event pump must not inherit AppDelegate's MainActor isolation"
        )
    }

    func testIndexErrorEventSurfacesAsDegraded() throws {
        let store = EngramServiceStatusStore()
        store.status = .running(total: 100, todayParents: 3)

        // Service emits {"event":"index_error","error":"..."} to stdout.
        let event = try decode(#"{"event":"index_error","error":"missing sessions table"}"#)
        AppDelegate.applyServiceEvent(event, to: store)

        guard case .degraded(let message) = store.status else {
            return XCTFail("index_error must produce a degraded status, got \(store.status)")
        }
        XCTAssertTrue(message.contains("Last index scan failed"))
        // The detail lives under the `error` key; it must not be dropped.
        XCTAssertTrue(message.contains("missing sessions table"))
    }

    func testIndexErrorDetailDecodesFromErrorKey() throws {
        let event = try decode(#"{"event":"index_error","error":"missing sessions table"}"#)
        XCTAssertEqual(event.errorDetail, "missing sessions table")
        XCTAssertNil(event.message)
    }

    func testIndexErrorWithoutMessageStillDegrades() throws {
        let store = EngramServiceStatusStore()
        let event = try decode(#"{"event":"index_error"}"#)
        AppDelegate.applyServiceEvent(event, to: store)
        guard case .degraded = store.status else {
            return XCTFail("index_error must degrade even when no message is mappable")
        }
    }

    func testSuccessfulIndexClearsDegradedAfterError() throws {
        let store = EngramServiceStatusStore()
        AppDelegate.applyServiceEvent(try decode(#"{"event":"index_error","error":"boom"}"#), to: store)
        XCTAssertFalse(store.isRunning)

        // A later successful scan ("indexed") restores running via the store's own path.
        AppDelegate.applyServiceEvent(try decode(#"{"event":"indexed","total":42,"todayParents":1}"#), to: store)
        XCTAssertEqual(store.status, .running(total: 42, todayParents: 1))
        XCTAssertTrue(store.isRunning)
    }

    func testNonIndexEventsPassThroughUnchanged() throws {
        let store = EngramServiceStatusStore()
        AppDelegate.applyServiceEvent(try decode(#"{"event":"warning","message":"slow"}"#), to: store)
        XCTAssertEqual(store.status, .degraded(message: "slow"))
    }
}
