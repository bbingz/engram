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

    /// LIVE integration: a real offload→rehydrate against a *deployed*
    /// `engram-remote` server over HTTPS (the only difference from the test above
    /// is the backend: `EngramRemoteBackend` instead of `LocalDirectoryBackend`).
    /// Skipped unless `ENGRAM_LIVE_OFFLOAD_URL` + `ENGRAM_LIVE_OFFLOAD_TOKEN` are
    /// set, so normal CI never touches the network. The seeded session's FTS
    /// content round-trips through the real client + TLS + server + AES-GCM
    /// at-rest; we assert the keyword shadow keeps it searchable while offloaded
    /// and the full content is restored byte-for-byte on rehydrate.
    func testLiveOffloadRehydrateAgainstDeployedServer() async throws {
        // Config from env (ENGRAM_LIVE_OFFLOAD_URL/_TOKEN) or, since xcodebuild
        // sanitizes the test-process environment, a `~/.engram-live-offload.json`
        // ({"url":...,"token":...}) fallback. Absent either → skip (CI never runs).
        let cfg = Self.liveConfig()
        guard let url = cfg?.url, let token = cfg?.token, !token.isEmpty else {
            throw XCTSkip("provide ENGRAM_LIVE_OFFLOAD_URL/_TOKEN or ~/.engram-live-offload.json to run the live offload test")
        }

        let paths = try makePaths()
        let gate = try ServiceWriterGate(databasePath: paths.database.path, runtimeDirectory: paths.runtime)
        _ = try await gate.performWriteCommand(name: "migrate") { writer in try writer.migrate() }

        let sessionId = "live-\(UUID().uuidString.prefix(8))"
        let fullContents = [
            "user: please deploy the remote offload server",
            "assistant: built, tested, and deployed to macmini over TLS",
            "session summary: remote offload end-to-end",
        ]
        _ = try await gate.performWriteCommand(name: "seed") { writer in
            try writer.write { db in
                try db.execute(sql: """
                    INSERT INTO sessions(id, source, start_time, end_time, file_path, project,
                                         summary, summary_message_count, message_count,
                                         user_message_count, assistant_message_count,
                                         generated_title, size_bytes, hidden_at)
                    VALUES (?, 'codex','2024-01-01T00:00:00Z','2024-01-01T01:00:00Z',
                            ?, 'proj','session summary: remote offload end-to-end',
                            3, 3, 1, 2, 'Live offload session', 8192, '2024-02-01T00:00:00Z');
                """, arguments: [sessionId, "/tmp/\(sessionId).jsonl"])
                for line in fullContents {
                    try db.execute(sql: "INSERT INTO sessions_fts(session_id, content) VALUES (?, ?)",
                                   arguments: [sessionId, line])
                }
            }
        }

        let backend = try EngramRemoteBackend(baseURL: url, token: token)
        let config = RemoteSyncConfig(
            enabled: true,
            storeRoot: paths.store,
            policy: OffloadPolicy(coldAgeDays: 90),
            offloadBatch: 20,
            rehydrateBatch: 20,
            vacuumFreelistThreshold: 1_000_000 // never vacuum in this test
        )
        let coordinator = RemoteSyncCoordinator(gate: gate, backend: backend, config: config, peer: "live-test")

        // Offload — real AES-GCM bundle PUT to the deployed server. State flips to
        // "offloaded" only after a confirmed remote PUT.
        let offload = try await coordinator.runOnce(now: Date())
        XCTAssertEqual(offload.offloaded, 1, "expected exactly the seeded session to offload")
        _ = try await gate.performWriteCommand(name: "check") { writer in
            try writer.read { db in
                XCTAssertEqual(try OffloadRepo.offloadState(db, sessionId: sessionId), "offloaded")
                let fts = try Int.fetchOne(
                    db, sql: "SELECT COUNT(*) FROM sessions_fts WHERE session_id = ?", arguments: [sessionId]
                )
                XCTAssertEqual(fts, 1, "offloaded session keeps only the keyword shadow")
            }
        }

        // Rehydrate — real GET from the deployed server; content restored exactly.
        let rehydrated = try await coordinator.rehydrateNow(sessionId: sessionId)
        XCTAssertTrue(rehydrated, "expected the offloaded session to rehydrate")
        _ = try await gate.performWriteCommand(name: "verify") { writer in
            try writer.read { db in
                XCTAssertEqual(try OffloadRepo.offloadState(db, sessionId: sessionId), "local")
                let restored = Set(try String.fetchAll(
                    db, sql: "SELECT content FROM sessions_fts WHERE session_id = ?", arguments: [sessionId]
                ))
                XCTAssertEqual(restored, Set(fullContents), "rehydrated FTS content must match the original")
            }
        }
    }

    /// Resolve live-test config from the environment first, then a
    /// `~/.engram-live-offload.json` file (xcodebuild strips the test-process env).
    private static func liveConfig() -> (url: URL, token: String)? {
        let env = ProcessInfo.processInfo.environment
        if let s = env["ENGRAM_LIVE_OFFLOAD_URL"], let url = URL(string: s),
           let token = env["ENGRAM_LIVE_OFFLOAD_TOKEN"], !token.isEmpty {
            return (url, token)
        }
        let file = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".engram-live-offload.json")
        guard let data = try? Data(contentsOf: file),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: String],
              let s = obj["url"], let url = URL(string: s),
              let token = obj["token"], !token.isEmpty else { return nil }
        return (url, token)
    }
}
