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

    // MARK: - Layer 2: per-project session-record sync

    private func seedLocal(
        _ gate: ServiceWriterGate, id: String, fts: [String],
        project: String = "demo", cwd: String = "/Users/bing/-Code-/demo"
    ) async throws {
        _ = try await gate.performWriteCommand(name: "seed") { writer in
            try writer.write { db in
                try db.execute(sql: """
                    INSERT INTO sessions(id, source, start_time, end_time, file_path, cwd, project,
                                         summary, summary_message_count, message_count,
                                         user_message_count, assistant_message_count, generated_title, size_bytes)
                    VALUES (?, 'codex','2024-01-01T00:00:00Z','2024-01-01T01:00:00Z',
                            ?, ?, ?, 'a summary', 2, 2, 1, 1, ?, 4096);
                """, arguments: [id, "/tmp/\(id).jsonl", cwd, project, "Title \(id)"])
                for line in fts {
                    try db.execute(sql: "INSERT INTO sessions_fts(session_id, content) VALUES (?, ?)",
                                   arguments: [id, line])
                }
            }
        }
    }

    /// Full push (peer A) → pull (peer B) round trip through a shared directory
    /// store: A publishes 2 sessions + manifest; B imports both as searchable
    /// peer-origin rows; re-pull is a no-op (dedup on content hash).
    func testPushThenPullProjectRoundTrip() async throws {
        let store = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("engram-syncproj-\(UUID().uuidString.prefix(8))", isDirectory: true)
            .appendingPathComponent("store", isDirectory: true)
        let pathsA = try makePaths(); let pathsB = try makePaths()
        let (coordA, gateA, _) = try makeCoordinatorSharedStore(pathsA, store: store, peer: "macA")
        let (coordB, gateB, _) = try makeCoordinatorSharedStore(pathsB, store: store, peer: "macB")
        _ = try await gateA.performWriteCommand(name: "migrate") { try $0.migrate() }
        _ = try await gateB.performWriteCommand(name: "migrate") { try $0.migrate() }

        try await seedLocal(gateA, id: "a1", fts: ["alpha bravo", "charlie"])
        try await seedLocal(gateA, id: "a2", fts: ["delta echo"])

        let pushed = try await coordA.pushProject(project: "demo", cwd: "/Users/bing/-Code-/demo")
        XCTAssertEqual(pushed.uploaded, 2)
        XCTAssertEqual(pushed.skipped, 0)

        // Publish-only invariant at the coordinator level: pushing must NOT collapse
        // the publisher's local FTS or flip offload_state (that is offload's job, not
        // publish's). Guards against a regression that routed push through
        // commitOffloaded — which the round-trip's import assertions alone would miss.
        _ = try await gateA.performWriteCommand(name: "verifyPublisher") { writer in
            try writer.read { db in
                XCTAssertEqual(
                    try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sessions_fts WHERE session_id = 'a1'"), 2,
                    "push must not collapse the publisher's FTS"
                )
                XCTAssertEqual(try OffloadRepo.offloadState(db, sessionId: "a1"), "local",
                               "push must not flip the publisher's offload_state")
            }
        }

        let pulled = try await coordB.pullProject(project: "demo")
        XCTAssertEqual(pulled.imported, 2)
        XCTAssertEqual(pulled.skipped, 0)

        _ = try await gateB.performWriteCommand(name: "verify") { writer in
            try writer.read { db in
                XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sessions WHERE origin = 'macA'"), 2)
                let id = ImportRepo.importedLocalId(peer: "macA", sessionId: "a1")
                let hits = try Int.fetchOne(
                    db, sql: "SELECT COUNT(*) FROM sessions_fts WHERE session_id = ? AND content MATCH 'bravo'",
                    arguments: [id]
                )
                XCTAssertEqual(hits, 1, "imported peer session is keyword searchable")
            }
        }

        // Re-pull is idempotent: nothing new, both skipped.
        let again = try await coordB.pullProject(project: "demo")
        XCTAssertEqual(again.imported, 0)
        XCTAssertEqual(again.skipped, 2)
    }

    /// Multi-project push must NOT drop earlier projects from the per-peer manifest
    /// (it merges, not full-replaces), and pull must scope strictly to the requested
    /// project. Peer A pushes "demo" then "other"; peer B pulling "demo" still imports
    /// demo's session (merge kept it) and does NOT import "other"'s (pull scoping).
    func testMultiProjectPushMergesManifestAndPullScopesByProject() async throws {
        let store = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("engram-syncmulti-\(UUID().uuidString.prefix(8))", isDirectory: true)
            .appendingPathComponent("store", isDirectory: true)
        let pathsA = try makePaths(); let pathsB = try makePaths()
        let (coordA, gateA, _) = try makeCoordinatorSharedStore(pathsA, store: store, peer: "macA")
        let (coordB, gateB, _) = try makeCoordinatorSharedStore(pathsB, store: store, peer: "macB")
        _ = try await gateA.performWriteCommand(name: "migrate") { try $0.migrate() }
        _ = try await gateB.performWriteCommand(name: "migrate") { try $0.migrate() }

        try await seedLocal(gateA, id: "a1", fts: ["alpha demo"],
                            project: "demo", cwd: "/Users/bing/-Code-/demo")
        try await seedLocal(gateA, id: "b1", fts: ["bravo other"],
                            project: "other", cwd: "/Users/bing/-Code-/other")

        // Push demo, THEN other. The second push must not drop demo from the manifest.
        let pushDemo = try await coordA.pushProject(project: "demo", cwd: "/Users/bing/-Code-/demo")
        XCTAssertEqual(pushDemo.uploaded, 1)
        let pushOther = try await coordA.pushProject(project: "other", cwd: "/Users/bing/-Code-/other")
        XCTAssertEqual(pushOther.uploaded, 1)

        // Pull "demo" on B: imports ONLY demo's a1 (merge kept it; scoping excludes b1).
        let pulledDemo = try await coordB.pullProject(project: "demo")
        XCTAssertEqual(pulledDemo.imported, 1, "demo survived the later 'other' push (manifest merge)")
        _ = try await gateB.performWriteCommand(name: "verify") { writer in
            try writer.read { db in
                XCTAssertNotNil(
                    try String.fetchOne(db, sql: "SELECT id FROM sessions WHERE id = ?",
                                        arguments: [ImportRepo.importedLocalId(peer: "macA", sessionId: "a1")]),
                    "demo session imported"
                )
                XCTAssertNil(
                    try String.fetchOne(db, sql: "SELECT id FROM sessions WHERE id = ?",
                                        arguments: [ImportRepo.importedLocalId(peer: "macA", sessionId: "b1")]),
                    "pull 'demo' must NOT import the 'other'-project session b1 (project scoping)"
                )
            }
        }

        // The 'other' project is still independently pullable too.
        let pulledOther = try await coordB.pullProject(project: "other")
        XCTAssertEqual(pulledOther.imported, 1, "'other' remains discoverable after demo was pushed first")
    }

    /// FAIL-CLOSED: if reading the existing per-peer manifest fails with a transient
    /// error (not a clean "absent"), pushProject must NOT full-replace the manifest
    /// with only the current project — that would drop every other project from
    /// discovery. It must throw and leave the existing manifest untouched.
    func testPushFailsClosedWhenExistingManifestGetFails() async throws {
        let store = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("engram-syncfailclosed-\(UUID().uuidString.prefix(8))", isDirectory: true)
            .appendingPathComponent("store", isDirectory: true)
        let paths = try makePaths()
        let gate = try ServiceWriterGate(databasePath: paths.database.path, runtimeDirectory: paths.runtime)
        _ = try await gate.performWriteCommand(name: "migrate") { try $0.migrate() }
        let inner = try LocalDirectoryBackend(root: store)
        let backend = FailingGetBackend(inner: inner, failKeySubstring: "catalog.")
        let config = RemoteSyncConfig(
            enabled: true, storeRoot: store, policy: OffloadPolicy(coldAgeDays: 90),
            offloadBatch: 20, rehydrateBatch: 20, vacuumFreelistThreshold: 1_000_000
        )
        let coord = RemoteSyncCoordinator(gate: gate, backend: backend, config: config, peer: "macA")

        try await seedLocal(gate, id: "a1", fts: ["alpha demo"],
                            project: "demo", cwd: "/Users/bing/-Code-/demo")
        try await seedLocal(gate, id: "b1", fts: ["bravo other"],
                            project: "other", cwd: "/Users/bing/-Code-/other")

        // First push writes the demo manifest cleanly (failure not yet armed).
        _ = try await coord.pushProject(project: "demo", cwd: "/Users/bing/-Code-/demo")
        let manifestKey = ManifestCodec.manifestKey(peer: "macA")
        let before = try await inner.get(key: manifestKey)

        // Arm a transient GET failure on the manifest read, then push "other".
        await backend.arm()
        do {
            _ = try await coord.pushProject(project: "other", cwd: "/Users/bing/-Code-/other")
            XCTFail("push must fail closed when the existing-manifest GET fails transiently")
        } catch {
            // expected — the error propagates instead of being swallowed.
        }

        // The on-disk manifest is untouched: demo's slice survives, not overwritten.
        let after = try await inner.get(key: manifestKey)
        XCTAssertEqual(after, before, "fail-closed: manifest not overwritten on a transient GET failure")
        let manifest = try ManifestCodec.decode(after)
        XCTAssertTrue(manifest.entries.contains { ($0.project ?? "").lowercased() == "demo" },
                      "demo entries preserved after the failed 'other' push")
    }

    /// Pull ignores this peer's OWN manifest (no echo / self-import).
    func testPullSkipsOwnManifest() async throws {
        let store = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("engram-syncself-\(UUID().uuidString.prefix(8))", isDirectory: true)
            .appendingPathComponent("store", isDirectory: true)
        let paths = try makePaths()
        let (coord, gate, _) = try makeCoordinatorSharedStore(paths, store: store, peer: "macA")
        _ = try await gate.performWriteCommand(name: "migrate") { try $0.migrate() }
        try await seedLocal(gate, id: "a1", fts: ["solo"])

        _ = try await coord.pushProject(project: "demo", cwd: "/Users/bing/-Code-/demo")
        let pulled = try await coord.pullProject(project: "demo")
        XCTAssertEqual(pulled.imported, 0, "must not import own published sessions")
        _ = try await gate.performWriteCommand(name: "verify") { writer in
            try writer.read { db in
                XCTAssertNil(try String.fetchOne(db, sql: "SELECT id FROM sessions WHERE origin = 'macA'"),
                             "no self-imported row")
            }
        }
    }

    /// Preview is read-only: push preview reports the actionable count + sample
    /// titles without uploading; pull preview reflects what would import.
    func testPreviewProjectSyncIsReadOnly() async throws {
        let store = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("engram-syncprev-\(UUID().uuidString.prefix(8))", isDirectory: true)
            .appendingPathComponent("store", isDirectory: true)
        let pathsA = try makePaths(); let pathsB = try makePaths()
        let (coordA, gateA, backendA) = try makeCoordinatorSharedStore(pathsA, store: store, peer: "macA")
        let (coordB, gateB, _) = try makeCoordinatorSharedStore(pathsB, store: store, peer: "macB")
        _ = try await gateA.performWriteCommand(name: "migrate") { try $0.migrate() }
        _ = try await gateB.performWriteCommand(name: "migrate") { try $0.migrate() }
        try await seedLocal(gateA, id: "a1", fts: ["alpha"])

        let pushPreview = try await coordA.previewProjectSync(
            project: "demo", cwd: "/Users/bing/-Code-/demo", direction: "push"
        )
        XCTAssertEqual(pushPreview.direction, "push")
        XCTAssertEqual(pushPreview.actionable, 1)
        XCTAssertEqual(pushPreview.skipped, 0)
        XCTAssertEqual(pushPreview.samples.map(\.title), ["Title a1"])
        XCTAssertEqual(pushPreview.samples.map(\.id), ["a1"], "preview carries the real session id, not the title")
        // Read-only: nothing uploaded.
        let manifestPublished = try await backendA.head(key: ManifestCodec.manifestKey(peer: "macA"))
        XCTAssertFalse(manifestPublished, "preview must not publish a manifest")

        // After a real push, B's pull preview shows 1 actionable.
        _ = try await coordA.pushProject(project: "demo", cwd: "/Users/bing/-Code-/demo")
        let pullPreview = try await coordB.previewProjectSync(
            project: "demo", cwd: "/Users/bing/-Code-/demo", direction: "pull"
        )
        XCTAssertEqual(pullPreview.direction, "pull")
        XCTAssertEqual(pullPreview.actionable, 1)
        XCTAssertEqual(pullPreview.samples.map(\.id), ["a1"],
                       "pull preview carries the publisher's real session id, not the title")
        _ = try await gateB.performWriteCommand(name: "verify") { writer in
            try writer.read { db in
                XCTAssertNil(try String.fetchOne(db, sql: "SELECT id FROM sessions WHERE origin = 'macA'"),
                             "pull preview must not import")
            }
        }
    }

    private func makeCoordinatorSharedStore(
        _ paths: (runtime: URL, database: URL, store: URL), store: URL, peer: String
    ) throws -> (RemoteSyncCoordinator, ServiceWriterGate, LocalDirectoryBackend) {
        let gate = try ServiceWriterGate(databasePath: paths.database.path, runtimeDirectory: paths.runtime)
        let backend = try LocalDirectoryBackend(root: store)
        let config = RemoteSyncConfig(
            enabled: true, storeRoot: store, policy: OffloadPolicy(coldAgeDays: 90),
            offloadBatch: 20, rehydrateBatch: 20, vacuumFreelistThreshold: 1_000_000
        )
        return (RemoteSyncCoordinator(gate: gate, backend: backend, config: config, peer: peer), gate, backend)
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

/// Test backend delegating to a real `LocalDirectoryBackend` but, once `arm()`ed,
/// failing `get` for keys containing `failKeySubstring` with a transient (non
/// "absent") error — to exercise pushProject's fail-closed manifest-merge path.
private actor FailingGetBackend: RemoteStorageBackend {
    private let inner: LocalDirectoryBackend
    private let failKeySubstring: String
    private var armed = false

    init(inner: LocalDirectoryBackend, failKeySubstring: String) {
        self.inner = inner
        self.failKeySubstring = failKeySubstring
    }

    func arm() { armed = true }

    func head(key: String) async throws -> Bool { try await inner.head(key: key) }
    func put(key: String, data: Data) async throws { try await inner.put(key: key, data: data) }
    func get(key: String) async throws -> Data {
        if armed, key.contains(failKeySubstring) {
            throw EngramRemoteBackendError.unexpectedStatus(503)
        }
        return try await inner.get(key: key)
    }
    func delete(key: String) async throws { try await inner.delete(key: key) }
    func catalog() async throws -> Data { try await inner.catalog() }
}
