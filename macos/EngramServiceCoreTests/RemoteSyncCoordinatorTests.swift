import XCTest
@testable import EngramServiceCore
import EngramCoreWrite

final class RemoteSyncCoordinatorTests: XCTestCase {
    private func makePaths() throws -> (runtime: URL, database: URL, store: URL) {
        let root = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("engram-remotesync-\(UUID().uuidString.prefix(8))", isDirectory: true)
        let runtime = root.appendingPathComponent("run", isDirectory: true)
        try FileManager.default.createDirectory(
            at: runtime, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        return (runtime, root.appendingPathComponent("gate.sqlite"), root.appendingPathComponent("store"))
    }

    func testCoordinatorOffloadsAndRehydratesThroughGate() async throws {
        let paths = try makePaths()
        let gate = try ServiceWriterGate(databasePath: paths.database.path, runtimeDirectory: paths.runtime)

        _ = try await gate.performWriteCommand(name: "migrate") { writer in try writer.migrate() }

        let fullContents = ["user asks a question", "assistant answers", "session summary text"]
        _ = try await gate.performWriteCommand(name: "seed") { writer in
            try writer.write { db in
                try db.execute(sql: """
                    INSERT INTO sessions(id, source, start_time, end_time, file_path, project,
                                         summary, summary_message_count, message_count,
                                         user_message_count, assistant_message_count,
                                         generated_title, size_bytes, hidden_at)
                    VALUES ('c-1','codex','2024-01-01T00:00:00Z','2024-01-01T01:00:00Z',
                            '/tmp/c-1.jsonl','proj','session summary text', 2, 2, 1, 1,
                            'Coordinator session', 8192, '2024-02-01T00:00:00Z');
                """)
                for line in fullContents {
                    try db.execute(sql: "INSERT INTO sessions_fts(session_id, content) VALUES ('c-1', ?)",
                                   arguments: [line])
                }
            }
        }

        let backend = try LocalDirectoryBackend(root: paths.store)
        let config = RemoteSyncConfig(
            enabled: true,
            storeRoot: paths.store,
            policy: OffloadPolicy(coldAgeDays: 90),
            offloadBatch: 20,
            rehydrateBatch: 20,
            vacuumFreelistThreshold: 1_000_000 // effectively never vacuum in this test
        )
        let coordinator = RemoteSyncCoordinator(gate: gate, backend: backend, config: config, peer: "test-peer")

        // Offload
        let first = try await coordinator.runOnce(now: Date())
        XCTAssertEqual(first.offloaded, 1)
        XCTAssertEqual(first.rehydrated, 0)

        _ = try await gate.performWriteCommand(name: "check") { writer in
            try writer.read { db in
                XCTAssertEqual(try OffloadRepo.offloadState(db, sessionId: "c-1"), "offloaded")
                let fts = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sessions_fts WHERE session_id = 'c-1'")
                XCTAssertEqual(fts, 1, "offloaded session keeps only the shadow")
            }
        }

        // Rehydrate
        _ = try await gate.performWriteCommand(name: "enqueueRehydrate") { writer in
            try writer.write { db in _ = try OffloadRepo.enqueueRehydrate(db, sessionId: "c-1") }
        }
        let second = try await coordinator.runOnce(now: Date())
        XCTAssertEqual(second.rehydrated, 1)

        _ = try await gate.performWriteCommand(name: "verify") { writer in
            try writer.read { db in
                XCTAssertEqual(try OffloadRepo.offloadState(db, sessionId: "c-1"), "local")
                let restored = Set(try String.fetchAll(db, sql: "SELECT content FROM sessions_fts WHERE session_id = 'c-1'"))
                XCTAssertEqual(restored, Set(fullContents))
            }
        }
    }
}
