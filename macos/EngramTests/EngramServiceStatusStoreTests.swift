import XCTest
@testable import Engram

@MainActor
final class EngramServiceStatusStoreTests: XCTestCase {
    func testDisplayStringAndRunningSemanticsMatchLegacyIndexerStatus() {
        let store = EngramServiceStatusStore()

        XCTAssertEqual(store.displayString, "Stopped")
        XCTAssertFalse(store.isRunning)

        store.status = .starting
        XCTAssertEqual(store.displayString, "Starting...")
        XCTAssertFalse(store.isRunning)

        store.status = .running(total: 42, todayParents: 5)
        XCTAssertEqual(store.displayString, "42 sessions indexed")
        XCTAssertTrue(store.isRunning)

        store.status = .error(message: "fail")
        XCTAssertEqual(store.displayString, "Error: fail")
        XCTAssertFalse(store.isRunning)
    }

    func testAppliesReadyIndexedAndSummaryEvents() throws {
        let store = EngramServiceStatusStore()

        store.apply(try decode(#"{"event":"ready","indexed":150,"total":200,"todayParents":11}"#))
        XCTAssertEqual(store.totalSessions, 200)
        XCTAssertEqual(store.todayParentSessions, 11)
        XCTAssertEqual(store.status, .running(total: 200, todayParents: 11))
        XCTAssertNotNil(store.lastEventAt)

        store.apply(try decode(#"{"event":"watcher_indexed","total":202,"todayParents":12}"#))
        XCTAssertEqual(store.totalSessions, 202)
        XCTAssertEqual(store.todayParentSessions, 12)

        store.apply(try decode(#"{"event":"summary_generated","sessionId":"sess-123","summary":"Built a feature","total":203,"todayParents":13}"#))
        XCTAssertEqual(store.lastSummarySessionId, "sess-123")
        XCTAssertEqual(store.totalSessions, 203)
        XCTAssertEqual(store.todayParentSessions, 13)
    }

    func testAppliesErrorAndDegradedEvents() throws {
        let store = EngramServiceStatusStore()

        store.apply(try decode(#"{"event":"warning","message":"slow provider"}"#))
        XCTAssertEqual(store.status, .degraded(message: "slow provider"))
        XCTAssertEqual(store.displayString, "Degraded: slow provider")

        store.apply(try decode(#"{"event":"error","message":"Something went wrong"}"#))
        XCTAssertEqual(store.status, .error(message: "Something went wrong"))
        XCTAssertEqual(store.displayString, "Error: Something went wrong")
    }

    func testDecodesLegacyUsageDataAlias() throws {
        let event = try decode("""
        {
          "event": "usage",
          "data": [
            {"source":"openai","metric":"requests","value":40,"limit":100,"resetAt":"2026-04-24T00:00:00Z","status":"ok"}
          ]
        }
        """)
        let store = EngramServiceStatusStore()

        store.apply(event)

        XCTAssertEqual(store.usageData.count, 1)
        XCTAssertEqual(store.usageData[0].source, "openai")
        XCTAssertEqual(store.usageData[0].metric, "requests")
        XCTAssertEqual(store.usageData[0].value, 40)
        XCTAssertEqual(store.usageData[0].limit, 100)
        XCTAssertEqual(store.usageData[0].status, "ok")
    }

    func testWebReadyMapsEndpointHealth() throws {
        let store = EngramServiceStatusStore()

        store.apply(try decode(#"{"event":"web_ready","port":3457,"host":"127.0.0.1"}"#))

        XCTAssertEqual(store.endpointHost, "127.0.0.1")
        XCTAssertEqual(store.endpointPort, 3457)
    }

    private func decode(_ json: String) throws -> EngramServiceEvent {
        try JSONDecoder().decode(EngramServiceEvent.self, from: Data(json.utf8))
    }
}
