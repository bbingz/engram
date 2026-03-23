// macos/EngramTests/IndexerProcessTests.swift
import XCTest
@testable import Engram

final class IndexerProcessTests: XCTestCase {

    override func setUpWithError() throws {
        try super.setUpWithError()
    }

    override func tearDownWithError() throws {
        try super.tearDownWithError()
    }

    // MARK: - Helper

    private func decodeDaemonEvent(_ json: String) throws -> DaemonEvent {
        let data = json.data(using: .utf8)!
        return try JSONDecoder().decode(DaemonEvent.self, from: data)
    }

    // MARK: - DaemonEvent decoding

    /// 1. Decode "ready" event with indexed and total
    func testDecodeReadyEvent() throws {
        let event = try decodeDaemonEvent("""
            {"event":"ready","indexed":150,"total":200}
        """)
        XCTAssertEqual(event.event, "ready")
        XCTAssertEqual(event.indexed, 150)
        XCTAssertEqual(event.total, 200)
        XCTAssertNil(event.message)
        XCTAssertNil(event.sessionId)
    }

    /// 2. Decode "error" event with message
    func testDecodeErrorEvent() throws {
        let event = try decodeDaemonEvent("""
            {"event":"error","message":"Something went wrong"}
        """)
        XCTAssertEqual(event.event, "error")
        XCTAssertEqual(event.message, "Something went wrong")
        XCTAssertNil(event.indexed)
        XCTAssertNil(event.total)
    }

    /// 3. Decode "watcher_indexed" event
    func testDecodeWatcherIndexedEvent() throws {
        let event = try decodeDaemonEvent("""
            {"event":"watcher_indexed","total":42}
        """)
        XCTAssertEqual(event.event, "watcher_indexed")
        XCTAssertEqual(event.total, 42)
    }

    /// 4. Decode "summary_generated" event with sessionId and summary
    func testDecodeSummaryGeneratedEvent() throws {
        let event = try decodeDaemonEvent("""
            {"event":"summary_generated","sessionId":"sess-123","summary":"Built a feature","total":50}
        """)
        XCTAssertEqual(event.event, "summary_generated")
        XCTAssertEqual(event.sessionId, "sess-123")
        XCTAssertEqual(event.summary, "Built a feature")
        XCTAssertEqual(event.total, 50)
    }

    /// 5. Decode "web_ready" event with port and host
    func testDecodeWebReadyEvent() throws {
        let event = try decodeDaemonEvent("""
            {"event":"web_ready","port":3457,"host":"127.0.0.1"}
        """)
        XCTAssertEqual(event.event, "web_ready")
        XCTAssertEqual(event.port, 3457)
        XCTAssertEqual(event.host, "127.0.0.1")
    }

    /// 6. Decode "db_maintenance" event with action and removed
    func testDecodeDbMaintenanceEvent() throws {
        let event = try decodeDaemonEvent("""
            {"event":"db_maintenance","action":"dedup","removed":3}
        """)
        XCTAssertEqual(event.event, "db_maintenance")
        XCTAssertEqual(event.action, "dedup")
        XCTAssertEqual(event.removed, 3)
    }

    /// 7. Empty object {} → decode THROWS because `event` is non-optional String
    func testEmptyObjectThrows() throws {
        XCTAssertThrowsError(try decodeDaemonEvent("{}")) { error in
            // Should be a DecodingError.keyNotFound for "event"
            guard case DecodingError.keyNotFound(let key, _) = error else {
                XCTFail("Expected DecodingError.keyNotFound, got \(error)")
                return
            }
            XCTAssertEqual(key.stringValue, "event")
        }
    }

    /// 8. Completely malformed JSON → decode fails
    func testMalformedJSONThrows() throws {
        let data = "not json at all".data(using: .utf8)!
        XCTAssertThrowsError(try JSONDecoder().decode(DaemonEvent.self, from: data))
    }

    // MARK: - Status enum

    /// 9. Status displayString for each case
    func testStatusDisplayString() throws {
        XCTAssertEqual(IndexerProcess.Status.stopped.displayString, "Stopped")
        XCTAssertEqual(IndexerProcess.Status.starting.displayString, "Starting...")
        XCTAssertEqual(IndexerProcess.Status.running(total: 42).displayString, "42 sessions indexed")
        XCTAssertEqual(IndexerProcess.Status.error("fail").displayString, "Error: fail")
    }

    /// 10. Status isRunning returns true only for .running
    func testStatusIsRunning() throws {
        XCTAssertFalse(IndexerProcess.Status.stopped.isRunning)
        XCTAssertFalse(IndexerProcess.Status.starting.isRunning)
        XCTAssertTrue(IndexerProcess.Status.running(total: 10).isRunning)
        XCTAssertFalse(IndexerProcess.Status.error("err").isRunning)
    }
}
