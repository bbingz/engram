import XCTest
@testable import EngramServiceCore
import EngramCoreWrite
import GRDB

final class RemoteSyncIPCTests: XCTestCase {
    // Hermetic: these tests assert the offload-DISABLED behavior, but
    // RemoteSyncConfig.read falls back to the developer's real ~/.engram/settings.json
    // (which may have remoteOffloadEnabled:true on a machine where offload is in use).
    // Force the env override so the suite is independent of the host's settings.
    override func setUp() {
        super.setUp()
        setenv("ENGRAM_REMOTE_OFFLOAD_ENABLED", "0", 1)
    }

    override func tearDown() {
        unsetenv("ENGRAM_REMOTE_OFFLOAD_ENABLED")
        super.tearDown()
    }

    private func makePaths() throws -> (runtime: URL, database: URL) {
        let root = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("engram-rsipc-\(UUID().uuidString.prefix(8))", isDirectory: true)
        let runtime = root.appendingPathComponent("run", isDirectory: true)
        try FileManager.default.createDirectory(
            at: runtime, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        return (runtime, root.appendingPathComponent("db.sqlite"))
    }

    private func makeHandler() async throws -> (EngramServiceCommandHandler, ServiceWriterGate) {
        let paths = try makePaths()
        let gate = try ServiceWriterGate(databasePath: paths.database.path, runtimeDirectory: paths.runtime)
        _ = try await gate.performWriteCommand(name: "migrate") { writer in try writer.migrate() }
        return (EngramServiceCommandHandler(writerGate: gate), gate)
    }

    private func seed(_ gate: ServiceWriterGate, id: String, offloadState: String) async throws {
        _ = try await gate.performWriteCommand(name: "seed") { writer in
            try writer.write { db in
                try db.execute(
                    sql: "INSERT INTO sessions(id, source, start_time, file_path, offload_state) VALUES (?, 'codex', '2024-01-01T00:00:00Z', ?, ?)",
                    arguments: [id, "/tmp/\(id).jsonl", offloadState]
                )
            }
        }
    }

    func testMutatingRemoteCommandsRequireCapabilityToken() {
        XCTAssertTrue(ServiceCapabilityToken.requiresToken("remoteOffload"))
        XCTAssertTrue(ServiceCapabilityToken.requiresToken("remoteRehydrate"))
        // Read-only status is ungated, like other read commands.
        XCTAssertFalse(ServiceCapabilityToken.requiresToken("remoteSyncStatus"))
        // Layer 2 per-project sync: push/pull mutate state and must be gated; the
        // read-only preview stays ungated.
        XCTAssertTrue(ServiceCapabilityToken.requiresToken("remotePushProject"))
        XCTAssertTrue(ServiceCapabilityToken.requiresToken("remotePullProject"))
        XCTAssertFalse(ServiceCapabilityToken.requiresToken("remoteProjectSyncPreview"))
    }

    func testRemoteSyncStatusReportsCounts() async throws {
        let (handler, gate) = try await makeHandler()
        try await seed(gate, id: "a", offloadState: "local")
        try await seed(gate, id: "b", offloadState: "offloaded")

        let response = await handler.handle(EngramServiceRequestEnvelope(command: "remoteSyncStatus"))
        guard case .success(_, let data, _) = response else { return XCTFail("remoteSyncStatus failed") }
        let status = try JSONDecoder().decode(EngramServiceRemoteSyncStatusResponse.self, from: data)
        XCTAssertEqual(status.localCount, 1)
        XCTAssertEqual(status.offloadedCount, 1)
        XCTAssertEqual(status.pendingOffload, 0)
        XCTAssertFalse(status.enabled, "offload is opt-in; disabled in the test environment")
    }

    func testRemoteOffloadIsNoOpWhenDisabled() async throws {
        let (handler, _) = try await makeHandler()
        let response = await handler.handle(EngramServiceRequestEnvelope(command: "remoteOffload"))
        guard case .success(_, let data, _) = response else { return XCTFail("remoteOffload failed") }
        let result = try JSONDecoder().decode(EngramServiceRemoteSyncCycleResponse.self, from: data)
        XCTAssertFalse(result.enabled)
        XCTAssertEqual(result.offloaded, 0)
        XCTAssertEqual(result.rehydrated, 0)
    }

    func testRecordSessionAccessEnqueuesRehydrateOnlyForOffloaded() async throws {
        let (handler, gate) = try await makeHandler()
        try await seed(gate, id: "off", offloadState: "offloaded")
        try await seed(gate, id: "loc", offloadState: "local")

        for id in ["off", "loc"] {
            let payload = try JSONEncoder().encode(EngramServiceSessionAccessRequest(sessionId: id))
            let response = await handler.handle(EngramServiceRequestEnvelope(command: "recordSessionAccess", payload: payload))
            guard case .success = response else { return XCTFail("recordSessionAccess(\(id)) failed") }
        }

        let queued = try await gate.performWriteCommand(name: "check") { writer in
            try writer.read { db in
                try String.fetchAll(db, sql: "SELECT session_id FROM rehydrate_queue WHERE status = 'pending'")
            }
        }.value
        XCTAssertEqual(queued, ["off"], "only the offloaded session is queued for lazy rehydrate on access")
    }
}
