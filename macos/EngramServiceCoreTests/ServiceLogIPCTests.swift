import XCTest
import GRDB
import Foundation
import EngramCoreWrite
@testable import EngramServiceCore

/// Command-handler + capability surface for the `serviceLogs` read command.
final class ServiceLogIPCTests: XCTestCase {
    func testServiceLogsCommandReturnsSanitizedSnapshot() async throws {
        let paths = try makeServicePaths()
        try seedSessionsFixture(at: paths.database.path)
        let gate = try ServiceWriterGate(databasePath: paths.database.path, runtimeDirectory: paths.runtime)
        let ring = ServiceLogRing(capacity: 100)
        await ring.record(level: "info", category: "runner", message: "ipc listener ready")
        await ring.record(
            level: "error",
            category: "ai",
            message: "indexing /Users/bing/.engram/index.sqlite now"
        )
        // Default Empty read provider: serviceLogs reads the ring (process state),
        // not the SQLite read provider.
        let handler = EngramServiceCommandHandler(writerGate: gate, logRing: ring)

        let response = await handler.handle(EngramServiceRequestEnvelope(command: "serviceLogs"))
        guard case .success(_, let data, _) = response else {
            return XCTFail("serviceLogs should succeed")
        }

        let snapshot = try JSONDecoder().decode(ServiceLogSnapshot.self, from: data)
        XCTAssertEqual(snapshot.lines.count, 2)
        // Newest-first.
        XCTAssertEqual(snapshot.lines.first?.category, "ai")
        // The path is sanitized in the stored line.
        let messages = snapshot.lines.map(\.message).joined(separator: "\n")
        XCTAssertFalse(messages.contains("/Users/bing/.engram/index.sqlite"))
        XCTAssertTrue(messages.contains("<path>"))
        XCTAssertTrue(messages.contains("ipc listener ready"))
    }

    func testServiceLogsReturnsEmptySnapshotWithoutRing() async throws {
        let paths = try makeServicePaths()
        try seedSessionsFixture(at: paths.database.path)
        let gate = try ServiceWriterGate(databasePath: paths.database.path, runtimeDirectory: paths.runtime)
        let handler = EngramServiceCommandHandler(writerGate: gate) // no ring installed

        let response = await handler.handle(EngramServiceRequestEnvelope(command: "serviceLogs"))
        guard case .success(_, let data, _) = response else {
            return XCTFail("serviceLogs should succeed even without a ring")
        }
        let snapshot = try JSONDecoder().decode(ServiceLogSnapshot.self, from: data)
        XCTAssertTrue(snapshot.lines.isEmpty)
    }

    func testServiceLogsIsExcludedFromTelemetrySpans() async throws {
        let paths = try makeServicePaths()
        try seedSessionsFixture(at: paths.database.path)
        let gate = try ServiceWriterGate(databasePath: paths.database.path, runtimeDirectory: paths.runtime)
        let collector = ServiceTelemetryCollector()
        let ring = ServiceLogRing(capacity: 10)
        let handler = EngramServiceCommandHandler(writerGate: gate, telemetry: collector, logRing: ring)

        _ = await handler.handle(EngramServiceRequestEnvelope(command: "serviceLogs"))

        let snapshot = await collector.snapshot()
        // serviceLogs reads the ring itself → excluded from telemetry span noise.
        XCTAssertFalse(snapshot.spans.contains(where: { $0.command == "serviceLogs" }))
    }

    func testServiceLogsDoesNotRequireCapabilityToken() {
        // serviceLogs is a READ command; it must NOT be in protectedCommands.
        XCTAssertFalse(ServiceCapabilityToken.requiresToken("serviceLogs"))
    }

    /// L02: malformed serviceLogs payloads must fail closed with invalidRequest
    /// instead of silently applying defaults via try?.
    func testServiceLogsMalformedPayloadReturnsInvalidRequest_repro() async throws {
        let paths = try makeServicePaths()
        try seedSessionsFixture(at: paths.database.path)
        let gate = try ServiceWriterGate(databasePath: paths.database.path, runtimeDirectory: paths.runtime)
        let handler = EngramServiceCommandHandler(writerGate: gate, logRing: ServiceLogRing())

        let malformed = EngramServiceRequestEnvelope(
            command: "serviceLogs",
            payload: Data(#"{"limit":"not-a-number"}"#.utf8)
        )
        let response = await handler.handle(malformed)
        guard case .failure(_, let error) = response else {
            return XCTFail("malformed serviceLogs payload must return error, not success defaults")
        }
        XCTAssertEqual(error.name, "InvalidRequest")
        XCTAssertFalse(error.message.isEmpty)
    }

    func testServiceLogsNonJSONPayloadReturnsInvalidRequest() async throws {
        let paths = try makeServicePaths()
        try seedSessionsFixture(at: paths.database.path)
        let gate = try ServiceWriterGate(databasePath: paths.database.path, runtimeDirectory: paths.runtime)
        let handler = EngramServiceCommandHandler(writerGate: gate, logRing: ServiceLogRing())

        let response = await handler.handle(
            EngramServiceRequestEnvelope(command: "serviceLogs", payload: Data("not-json".utf8))
        )
        guard case .failure(_, let error) = response else {
            return XCTFail("non-JSON serviceLogs payload must return InvalidRequest")
        }
        XCTAssertEqual(error.name, "InvalidRequest")
    }

    func testServiceLogsEmptyObjectPayloadStillSucceedsWithDefaults() async throws {
        let paths = try makeServicePaths()
        try seedSessionsFixture(at: paths.database.path)
        let gate = try ServiceWriterGate(databasePath: paths.database.path, runtimeDirectory: paths.runtime)
        let ring = ServiceLogRing(capacity: 10)
        await ring.record(level: "info", category: "runner", message: "hello")
        let handler = EngramServiceCommandHandler(writerGate: gate, logRing: ring)

        let response = await handler.handle(
            EngramServiceRequestEnvelope(command: "serviceLogs", payload: Data("{}".utf8))
        )
        guard case .success(_, let data, _) = response else {
            return XCTFail("valid empty object payload must still succeed")
        }
        let snapshot = try JSONDecoder().decode(ServiceLogSnapshot.self, from: data)
        XCTAssertEqual(snapshot.lines.count, 1)
    }

    // MARK: - Helpers

    private func makeServicePaths() throws -> (runtime: URL, socket: URL, database: URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("engram-servicelogs-\(UUID().uuidString.prefix(8))", isDirectory: true)
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

    private func seedSessionsFixture(at path: String) throws {
        var configuration = Configuration()
        configuration.prepareDatabase { db in
            try db.execute(sql: "PRAGMA journal_mode = WAL")
        }
        let queue = try DatabaseQueue(path: path, configuration: configuration)
        try queue.write { db in
            try db.execute(sql: """
                CREATE TABLE sessions (
                  id TEXT PRIMARY KEY,
                  source TEXT NOT NULL,
                  start_time TEXT NOT NULL,
                  cwd TEXT NOT NULL DEFAULT '',
                  file_path TEXT NOT NULL DEFAULT '',
                  message_count INTEGER NOT NULL DEFAULT 0,
                  size_bytes INTEGER NOT NULL DEFAULT 0,
                  indexed_at TEXT NOT NULL DEFAULT '',
                  hidden_at TEXT
                );
            """)
        }
    }
}
