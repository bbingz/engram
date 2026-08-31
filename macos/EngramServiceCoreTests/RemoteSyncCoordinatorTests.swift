import XCTest
@testable import EngramServiceCore
import EngramCoreRead
import EngramCoreWrite

final class RemoteSyncCoordinatorTests: XCTestCase {
    private struct TestLiveArtifact {
        let entry: SyncManifestEntry
        let bundle: RemoteSessionBundle
    }

    private func makePaths() throws -> (runtime: URL, database: URL, store: URL) {
        let root = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("engram-remotesync-\(UUID().uuidString.prefix(8))", isDirectory: true)
        let runtime = root.appendingPathComponent("run", isDirectory: true)
        try FileManager.default.createDirectory(
            at: runtime, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        return (runtime, root.appendingPathComponent("gate.sqlite"), root.appendingPathComponent("store"))
    }

    func testRemoteSyncConfigTLSOverrideFailsClosedAndFallsBackToSettings_repro() throws {
        let home = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("engram-remote-config-\(UUID().uuidString.prefix(8))", isDirectory: true)
        let settingsDirectory = home.appendingPathComponent(".engram", isDirectory: true)
        try FileManager.default.createDirectory(at: settingsDirectory, withIntermediateDirectories: true)
        try Data(#"{"remoteOffloadRequireTLS":false}"#.utf8).write(
            to: settingsDirectory.appendingPathComponent("settings.json")
        )

        XCTAssertFalse(RemoteSyncConfig.read(environment: [:], homeDirectory: home).requireTLS)
        XCTAssertTrue(
            RemoteSyncConfig.read(
                environment: [:],
                homeDirectory: home.appendingPathComponent("without-settings", isDirectory: true)
            ).requireTLS
        )
        for invalid in ["", "garbage", " true-ish "] {
            XCTAssertTrue(
                RemoteSyncConfig.read(
                    environment: ["ENGRAM_REMOTE_OFFLOAD_REQUIRE_TLS": invalid],
                    homeDirectory: home
                ).requireTLS,
                "present invalid override '\(invalid)' must fail closed, not disable TLS"
            )
        }
        for explicitFalse in ["0", "false", "no", " FALSE "] {
            XCTAssertFalse(
                RemoteSyncConfig.read(
                    environment: ["ENGRAM_REMOTE_OFFLOAD_REQUIRE_TLS": explicitFalse],
                    homeDirectory: home
                ).requireTLS
            )
        }
    }

    func testRemoteSyncEntryPointsReadSettingsFromTheInjectedHome_repro() async throws {
        let paths = try makePaths()
        let root = paths.runtime.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home", isDirectory: true)
        let settingsDirectory = home.appendingPathComponent(".engram", isDirectory: true)
        try FileManager.default.createDirectory(at: settingsDirectory, withIntermediateDirectories: true)
        try Data(
            """
            {"remoteOffloadEnabled":true,"remoteOffloadStoreRoot":"\(paths.store.path)"}
            """.utf8
        ).write(to: settingsDirectory.appendingPathComponent("settings.json"))
        let environment = [
            "HOME": home.path,
            "CFFIXED_USER_HOME": home.path,
        ]
        let gate = try ServiceWriterGate(databasePath: paths.database.path, runtimeDirectory: paths.runtime)
        _ = try await gate.performWriteCommand(name: "migrate") { try $0.migrate() }

        XCTAssertNotNil(try RemoteSyncCoordinator.makeIfEnabled(gate: gate, environment: environment))
        let status = try await EngramServiceCommandHandler.remoteSyncStatus(
            writerGate: gate,
            environment: environment
        )
        XCTAssertTrue(status.enabled)
        XCTAssertEqual(status.backendKind, "local")
    }

    func testEnabledRemoteBackendInitializationErrorPropagatesAndStatusDoesNotLie_repro() async throws {
        let paths = try makePaths()
        let gate = try ServiceWriterGate(databasePath: paths.database.path, runtimeDirectory: paths.runtime)
        _ = try await gate.performWriteCommand(name: "migrate") { try $0.migrate() }
        let environment = [
            "ENGRAM_REMOTE_OFFLOAD_ENABLED": "1",
            "ENGRAM_REMOTE_OFFLOAD_BACKEND": "http",
            "ENGRAM_REMOTE_OFFLOAD_SERVER_URL": "http://example.com",
            "ENGRAM_REMOTE_OFFLOAD_TOKEN": "test-token",
            "ENGRAM_REMOTE_OFFLOAD_REQUIRE_TLS": "true",
        ]

        XCTAssertThrowsError(
            try RemoteSyncCoordinator.makeIfEnabled(gate: gate, environment: environment)
        ) { error in
            XCTAssertEqual(error as? EngramRemoteBackendError, .insecureURL("http://example.com"))
        }

        do {
            _ = try await EngramServiceCommandHandler.remoteSyncStatus(
                writerGate: gate,
                environment: environment
            )
            XCTFail("status must surface a configured backend error instead of reporting enabled=true")
        } catch {
            XCTAssertEqual(error as? EngramRemoteBackendError, .insecureURL("http://example.com"))
        }
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

    func testCoordinatorPreservesLocalFtsWhenExistingRemoteBundleHasWrongContent_repro() async throws {
        let paths = try makePaths()
        let gate = try ServiceWriterGate(databasePath: paths.database.path, runtimeDirectory: paths.runtime)
        _ = try await gate.performWriteCommand(name: "migrate") { try $0.migrate() }

        let fullContents = ["first original row", "second original row", "third original row"]
        _ = try await gate.performWriteCommand(name: "seed") { writer in
            try writer.write { db in
                try db.execute(sql: """
                    INSERT INTO sessions(id, source, start_time, file_path, size_bytes, hidden_at)
                    VALUES ('c-1', 'codex', '2024-01-01T00:00:00Z', '/tmp/c-1.jsonl', 4096, '2024-02-01T00:00:00Z')
                """)
                for line in fullContents {
                    try db.execute(
                        sql: "INSERT INTO sessions_fts(session_id, content) VALUES ('c-1', ?)",
                        arguments: [line]
                    )
                }
            }
        }

        let wrongBundle = BundleCodec.makeBundle(
            sessionId: "c-1",
            ftsContents: ["valid remote bundle for the same session, but stale content"],
            summary: nil,
            summaryMessageCount: nil,
            messageCount: 1,
            userMessageCount: 1,
            assistantMessageCount: 0,
            toolMessageCount: 0,
            systemMessageCount: 0
        )
        let backend = ExistingWrongBundleBackend(data: try BundleCodec.encode(wrongBundle))
        let config = RemoteSyncConfig(
            enabled: true,
            storeRoot: paths.store,
            policy: OffloadPolicy(coldAgeDays: 90),
            offloadBatch: 20,
            rehydrateBatch: 20,
            vacuumFreelistThreshold: 1_000_000
        )
        let coordinator = RemoteSyncCoordinator(gate: gate, backend: backend, config: config, peer: "test-peer")

        let result = try await coordinator.runOnce(now: Date())

        XCTAssertEqual(result.offloaded, 0)
        _ = try await gate.performWriteCommand(name: "verify") { writer in
            try writer.read { db in
                XCTAssertEqual(try OffloadRepo.offloadState(db, sessionId: "c-1"), "local")
                XCTAssertEqual(
                    try String.fetchAll(
                        db,
                        sql: "SELECT content FROM sessions_fts WHERE session_id = 'c-1' ORDER BY rowid"
                    ),
                    fullContents,
                    "a mismatched durability proof must preserve every original FTS row"
                )
                XCTAssertEqual(
                    try Int.fetchOne(
                        db,
                        sql: "SELECT COUNT(*) FROM sync_ledger WHERE session_id = 'c-1' AND direction = 'out'"
                    ),
                    0,
                    "commitOffloaded must not be reached"
                )
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

    private func writeLiveSnapshot(
        _ gate: ServiceWriterGate,
        id: String,
        snapshotHash: String,
        summary: String,
        startTime: String = "2024-01-01T00:00:00Z"
    ) async throws {
        _ = try await gate.performWriteCommand(name: "indexRecent") { writer in
            try writer.write { db in
                try SessionSnapshotWriter(db: db).writeAuthoritativeSnapshot(
                    AuthoritativeSessionSnapshot(
                        id: id,
                        source: .codex,
                        authoritativeNode: "",
                        syncVersion: 1,
                        snapshotHash: snapshotHash,
                        indexedAt: "2026-08-30T12:00:00Z",
                        sourceLocator: "/tmp/\(id).jsonl",
                        sizeBytes: 8192,
                        startTime: startTime,
                        endTime: "2024-01-01T01:00:01Z",
                        cwd: "/Users/bing/-Code-/demo",
                        project: "demo",
                        messageCount: 3,
                        userMessageCount: 2,
                        assistantMessageCount: 1,
                        toolMessageCount: 0,
                        systemMessageCount: 0,
                        summary: summary,
                        summaryMessageCount: 3,
                        origin: "local",
                        tier: .normal
                    )
                )
            }
        }
    }

    private func drainLiveFts(_ gate: ServiceWriterGate, contents: [String]) async throws {
        let adapter = RunnerTwoPhaseFTSAdapter(contents: contents)
        _ = try await gate.performWriteCommand(name: "periodicFtsDrain") { writer in
            try await IndexJobRunner(writer: writer, adapters: [adapter]).runRecoverableJobs()
        }
    }

    private func makeLiveArtifact(
        sessionId: String,
        text: String,
        advertisedContentHash: String? = nil
    ) -> TestLiveArtifact {
        let bundle = BundleCodec.makeBundle(
            sessionId: sessionId,
            ftsContents: [text],
            summary: text,
            summaryMessageCount: 1,
            messageCount: 1,
            userMessageCount: 1,
            assistantMessageCount: 0,
            toolMessageCount: 0,
            systemMessageCount: 0,
            tier: "normal"
        )
        return TestLiveArtifact(
            entry: SyncManifestEntry(
                sessionId: sessionId,
                source: "codex",
                project: "demo",
                title: sessionId,
                startTime: "2026-08-30T00:00:00Z",
                endTime: nil,
                messageCount: 1,
                userMessageCount: 1,
                assistantMessageCount: 0,
                systemMessageCount: 0,
                toolMessageCount: 0,
                summary: text,
                summaryMessageCount: 1,
                sizeBytes: 1,
                tier: "normal",
                remoteKey: BundleCodec.contentKey(bundle),
                contentHash: advertisedContentHash ?? bundle.contentHash
            ),
            bundle: bundle
        )
    }

    private func storeLiveSnapshot(
        backend: any RemoteStorageBackend,
        sourcePeer: String,
        generation: Int,
        seq: Int,
        artifacts: [TestLiveArtifact],
        headPeer: String? = nil,
        manifestPeer: String? = nil,
        manifestKey: String? = nil,
        complete: Bool = true,
        withdrawnCount: Int = 0
    ) async throws {
        for artifact in artifacts {
            try await backend.put(
                key: artifact.entry.remoteKey,
                data: try BundleCodec.encode(artifact.bundle)
            )
        }
        let manifest = SyncManifest(
            peer: manifestPeer ?? sourcePeer,
            updatedAt: "2026-08-30T00:00:00Z",
            entries: artifacts.map(\.entry)
        )
        let manifestData = try ManifestCodec.encodeLiveManifest(manifest)
        let storedManifestKey = manifestKey
            ?? LiveIngestKeys.manifest(peer: sourcePeer, generation: generation, seq: seq)
        try await backend.put(key: storedManifestKey, data: manifestData)
        let head = LiveIngestHead(
            peer: headPeer ?? sourcePeer,
            generation: generation,
            seq: seq,
            complete: complete,
            entryCount: artifacts.count,
            manifestKey: storedManifestKey,
            contentHash: ManifestCodec.liveManifestContentHash(manifestData),
            withdrawnCount: withdrawnCount
        )
        try await backend.put(
            key: LiveIngestKeys.head(peer: sourcePeer),
            data: try ManifestCodec.encodeLiveHead(head)
        )
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

    func testPullRetractsPreviouslyImportedSessionsWhenPeerMarksThemSkipOrChild_repro() async throws {
        let store = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("engram-syncretract-\(UUID().uuidString.prefix(8))", isDirectory: true)
            .appendingPathComponent("store", isDirectory: true)
        let pathsA = try makePaths(); let pathsB = try makePaths()
        let (coordA, gateA, backendA) = try makeCoordinatorSharedStore(pathsA, store: store, peer: "macA")
        let (coordB, gateB, _) = try makeCoordinatorSharedStore(pathsB, store: store, peer: "macB")
        _ = try await gateA.performWriteCommand(name: "migrate") { try $0.migrate() }
        _ = try await gateB.performWriteCommand(name: "migrate") { try $0.migrate() }
        try await seedLocal(gateA, id: "a1", fts: ["must disappear"])
        try await seedLocal(gateA, id: "a2", fts: ["child must disappear"])

        _ = try await coordA.pushProject(project: "demo", cwd: "/Users/bing/-Code-/demo")
        let firstPull = try await coordB.pullProject(project: "demo")
        XCTAssertEqual(firstPull.imported, 2)

        let manifestKey = ManifestCodec.manifestKey(peer: "macA")
        let published = try ManifestCodec.decode(await backendA.get(key: manifestKey))
        let withdrawn = published.entries.map { original in
            SyncManifestEntry(
                sessionId: original.sessionId,
                source: original.source,
                project: original.project,
                title: original.title,
                startTime: original.startTime,
                endTime: original.endTime,
                messageCount: original.messageCount,
                userMessageCount: original.userMessageCount,
                assistantMessageCount: original.assistantMessageCount,
                systemMessageCount: original.systemMessageCount,
                toolMessageCount: original.toolMessageCount,
                summary: original.summary,
                summaryMessageCount: original.summaryMessageCount,
                sizeBytes: original.sizeBytes,
                tier: original.sessionId == "a1" ? "skip" : original.tier,
                remoteKey: original.remoteKey,
                contentHash: original.contentHash,
                parentSessionId: original.sessionId == "a2" ? "a1" : nil
            )
        }
        try await backendA.put(
            key: manifestKey,
            data: ManifestCodec.encode(SyncManifest(peer: "macA", updatedAt: "2026-08-22T00:00:00Z", entries: withdrawn))
        )

        _ = try await coordB.pullProject(project: "demo")
        _ = try await gateB.performWriteCommand(name: "verifyRetracted") { writer in
            try writer.read { db in
                for sessionId in ["a1", "a2"] {
                    let importedID = ImportRepo.importedLocalId(peer: "macA", sessionId: sessionId)
                    XCTAssertNil(try String.fetchOne(db, sql: "SELECT id FROM sessions WHERE id = ?", arguments: [importedID]))
                    XCTAssertEqual(
                        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sessions_fts WHERE session_id = ?", arguments: [importedID]),
                        0
                    )
                }
            }
        }
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

    func testLiveCoordinatorExistsWhenOffloadDisabled_repro() throws {
        let paths = try makePaths()
        let root = paths.runtime.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home", isDirectory: true)
        let settingsDirectory = home.appendingPathComponent(".engram", isDirectory: true)
        try FileManager.default.createDirectory(at: settingsDirectory, withIntermediateDirectories: true)
        try Data(
            """
            {"remoteOffloadEnabled":false,"remoteOffloadStoreRoot":"\(paths.store.path)","livePublishEnabled":true,"liveIngestPeerId":"hq"}
            """.utf8
        ).write(to: settingsDirectory.appendingPathComponent("settings.json"))
        let environment = [
            "HOME": home.path,
            "CFFIXED_USER_HOME": home.path,
        ]
        let gate = try ServiceWriterGate(databasePath: paths.database.path, runtimeDirectory: paths.runtime)

        XCTAssertNil(
            try RemoteSyncCoordinator.makeIfEnabled(gate: gate, environment: environment),
            "offload constructor must stay off when remoteOffloadEnabled is false"
        )
        let live = try RemoteSyncCoordinator.makeLiveIfEnabled(gate: gate, environment: environment)
        XCTAssertNotNil(live, "live publish must construct a backend without arming offload")
        let config = LiveIngestConfig.read(environment: environment, homeDirectory: home)
        XCTAssertEqual(config.resolvedPeer, "hq")
        XCTAssertTrue(config.publishEnabled)
        XCTAssertFalse(config.ingestEnabled)
    }

    func testLivePeerIdFailsClosedWithoutExplicitPeer_repro() throws {
        let paths = try makePaths()
        let root = paths.runtime.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home", isDirectory: true)
        let settingsDirectory = home.appendingPathComponent(".engram", isDirectory: true)
        try FileManager.default.createDirectory(at: settingsDirectory, withIntermediateDirectories: true)
        try Data(
            """
            {"remoteOffloadEnabled":false,"remoteOffloadStoreRoot":"\(paths.store.path)","livePublishEnabled":true}
            """.utf8
        ).write(to: settingsDirectory.appendingPathComponent("settings.json"))
        let environment = [
            "HOME": home.path,
            "CFFIXED_USER_HOME": home.path,
        ]
        let gate = try ServiceWriterGate(databasePath: paths.database.path, runtimeDirectory: paths.runtime)
        let config = LiveIngestConfig.read(environment: environment, homeDirectory: home)
        XCTAssertNil(config.resolvedPeer, "empty peer keys must not fall through to hostname")
        XCTAssertNil(try RemoteSyncCoordinator.makeLiveIfEnabled(gate: gate, environment: environment))
    }

    func testLiveMacSourcesDivergeFromPeerIdFailsClosed_repro() throws {
        let paths = try makePaths()
        let root = paths.runtime.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home", isDirectory: true)
        let settingsDirectory = home.appendingPathComponent(".engram", isDirectory: true)
        try FileManager.default.createDirectory(at: settingsDirectory, withIntermediateDirectories: true)
        try Data(
            """
            {"remoteOffloadEnabled":false,"remoteOffloadStoreRoot":"\(paths.store.path)","liveIngestEnabled":true,"liveIngestPeerId":"hq","liveIngestSources":["other"]}
            """.utf8
        ).write(to: settingsDirectory.appendingPathComponent("settings.json"))
        let environment = [
            "HOME": home.path,
            "CFFIXED_USER_HOME": home.path,
        ]
        let gate = try ServiceWriterGate(databasePath: paths.database.path, runtimeDirectory: paths.runtime)
        XCTAssertNil(
            try RemoteSyncCoordinator.makeLiveIfEnabled(gate: gate, environment: environment),
            "Mac pull identity must fail closed when liveIngestPeerId and liveIngestSources diverge"
        )
    }

    func testLivePublishAndIngestSelfLoopFailsClosed_repro() throws {
        let paths = try makePaths()
        let root = paths.runtime.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home", isDirectory: true)
        let settingsDirectory = home.appendingPathComponent(".engram", isDirectory: true)
        try FileManager.default.createDirectory(at: settingsDirectory, withIntermediateDirectories: true)
        try Data(
            """
            {"remoteOffloadEnabled":false,"remoteOffloadStoreRoot":"\(paths.store.path)","livePublishEnabled":true,"liveIngestEnabled":true,"liveIngestPeerId":"hq","liveIngestSources":["hq"]}
            """.utf8
        ).write(to: settingsDirectory.appendingPathComponent("settings.json"))
        let environment = [
            "HOME": home.path,
            "CFFIXED_USER_HOME": home.path,
        ]
        let gate = try ServiceWriterGate(databasePath: paths.database.path, runtimeDirectory: paths.runtime)
        let config = LiveIngestConfig.read(environment: environment, homeDirectory: home)

        XCTAssertFalse(config.isLiveIdentityValid)
        XCTAssertNil(
            try RemoteSyncCoordinator.makeLiveIfEnabled(gate: gate, environment: environment),
            "a peer must not publish and ingest its own live namespace"
        )
    }

    func testLivePullImportsPublishableRowIntoFtsWithHqOrigin_repro() async throws {
        let store = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("engram-liveimp-\(UUID().uuidString.prefix(8))", isDirectory: true)
            .appendingPathComponent("store", isDirectory: true)
        let pathsA = try makePaths(); let pathsB = try makePaths()
        defer {
            try? FileManager.default.removeItem(at: pathsA.runtime.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: pathsB.runtime.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: store.deletingLastPathComponent())
        }
        let (coordHQ, gateHQ, backend) = try makeCoordinatorSharedStore(pathsA, store: store, peer: "hq")
        let (coordMac, gateMac, _) = try makeCoordinatorSharedStore(pathsB, store: store, peer: "mac")
        _ = try await gateHQ.performWriteCommand(name: "migrate") { try $0.migrate() }
        _ = try await gateMac.performWriteCommand(name: "migrate") { try $0.migrate() }
        try await seedLocal(gateHQ, id: "hq1", fts: ["unique hq keyword"])

        let published = try await coordHQ.publishLivePeer(batch: 50, completeWalk: true)
        XCTAssertEqual(published.publishedEntries, 1)
        XCTAssertTrue(published.complete)
        _ = try await gateHQ.performWriteCommand(name: "hqFts") { writer in
            try writer.read { db in
                XCTAssertEqual(
                    try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sessions_fts WHERE session_id = 'hq1'"),
                    1,
                    "HQ publish must not collapse source FTS"
                )
                XCTAssertEqual(try OffloadRepo.offloadState(db, sessionId: "hq1"), "local")
            }
        }

        let catalog = try ManifestCodec.decodeCatalog(await backend.catalog())
        XCTAssertEqual(catalog, [], "live listing must not appear in GET /v1/catalog")
        let hasLiveHead = try await backend.head(key: LiveIngestKeys.head(peer: "hq"))
        XCTAssertTrue(hasLiveHead)

        let pulled = try await coordMac.pullLivePeer(peer: "hq")
        XCTAssertEqual(pulled.imported, 1)
        let localId = ImportRepo.importedLocalId(peer: "hq", sessionId: "hq1")
        _ = try await gateMac.performWriteCommand(name: "verify") { writer in
            try writer.read { db in
                XCTAssertEqual(
                    try String.fetchOne(db, sql: "SELECT origin FROM sessions WHERE id = ?", arguments: [localId]),
                    "hq"
                )
                XCTAssertEqual(
                    try String.fetchOne(db, sql: "SELECT file_path FROM sessions WHERE id = ?", arguments: [localId]),
                    "remote://hq/hq1"
                )
                XCTAssertEqual(
                    try Int.fetchOne(
                        db,
                        sql: "SELECT COUNT(*) FROM sessions_fts WHERE session_id = ? AND content MATCH 'keyword'",
                        arguments: [localId]
                    ),
                    1
                )
                XCTAssertEqual(try OffloadRepo.livePublishCandidates(db, limit: 50).map(\.id), [])
                XCTAssertEqual(try OffloadRepo.candidateRows(db, limit: 50).map(\.id), [])
            }
        }
    }

    func testUnchangedLivePublishPerformsNoFtsReadHeadUploadOrWrite_repro() async throws {
        let paths = try makePaths()
        defer { try? FileManager.default.removeItem(at: paths.runtime.deletingLastPathComponent()) }
        let gate = try ServiceWriterGate(databasePath: paths.database.path, runtimeDirectory: paths.runtime)
        _ = try await gate.performWriteCommand(name: "migrate") { try $0.migrate() }
        try await seedLocal(gate, id: "unchanged", fts: ["stable corpus"])

        let inner = try LocalDirectoryBackend(root: paths.store)
        let backend = RecordingRemoteStorageBackend(inner: inner)
        let coordinator = RemoteSyncCoordinator(
            gate: gate,
            backend: backend,
            config: RemoteSyncConfig(
                enabled: true,
                storeRoot: paths.store,
                policy: OffloadPolicy(coldAgeDays: 90),
                offloadBatch: 20,
                rehydrateBatch: 20,
                vacuumFreelistThreshold: 1_000_000
            ),
            peer: "hq"
        )

        let first = try await coordinator.publishLivePeer(batch: 50, completeWalk: true)
        XCTAssertEqual(first.uploaded, 1)
        XCTAssertTrue(first.complete)

        // An unchanged republish must be able to use the peer ledger without
        // touching FTS. Removing the isolated test table turns any accidental
        // full-content reread into a deterministic failure.
        _ = try await gate.performWriteCommand(name: "installFtsReadTrap") { writer in
            try writer.write { db in try db.execute(sql: "DROP TABLE sessions_fts") }
        }
        await backend.resetObservations()
        let generationBefore = await gate.currentDatabaseGeneration()

        let second = try await coordinator.publishLivePeer(batch: 50, completeWalk: true)

        XCTAssertEqual(second.uploaded, 0)
        XCTAssertEqual(second.skipped, 1)
        XCTAssertEqual(second.generation, first.generation)
        XCTAssertEqual(second.seq, first.seq)
        let observations = await backend.observations()
        XCTAssertEqual(observations.headKeys, [])
        XCTAssertEqual(observations.putKeys, [])
        let generationAfter = await gate.currentDatabaseGeneration()
        XCTAssertEqual(
            generationAfter,
            generationBefore,
            "unchanged publish must not enter a writer command"
        )
    }

    func testSuccessfulLiveRetractionAcknowledgesDelta_repro() async throws {
        let paths = try makePaths()
        defer { try? FileManager.default.removeItem(at: paths.runtime.deletingLastPathComponent()) }
        let (coordinator, gate, backend) = try makeCoordinatorSharedStore(
            paths, store: paths.store, peer: "hq"
        )
        _ = try await gate.performWriteCommand(name: "migrate") { try $0.migrate() }
        try await seedLocal(gate, id: "retract-once", fts: ["published before skip"])

        let initial = try await coordinator.publishLivePeer(batch: 50, completeWalk: true)
        XCTAssertTrue(initial.complete)
        XCTAssertEqual(initial.publishedEntries, 1)

        _ = try await gate.performWriteCommand(name: "makeIneligible") { writer in
            try writer.write { db in
                try db.execute(sql: "UPDATE sessions SET tier = 'skip' WHERE id = 'retract-once'")
            }
        }
        let pendingBefore = try await gate.performReadCommand(name: "pendingBeforeRetract") { writer in
            try writer.read { db in try OffloadRepo.hasLivePublishDelta(db, peer: "hq") }
        }.value
        XCTAssertTrue(pendingBefore)

        let retracted = try await coordinator.publishLivePeer(batch: 50, completeWalk: false)
        XCTAssertTrue(retracted.complete)
        XCTAssertEqual(retracted.publishedEntries, 0)
        let head = try ManifestCodec.decodeLiveHead(
            try await backend.get(key: LiveIngestKeys.head(peer: "hq"))
        )
        let manifest = try ManifestCodec.decodeLiveManifest(
            try await backend.get(key: head.manifestKey)
        )
        XCTAssertTrue(head.complete)
        XCTAssertEqual(manifest.entries, [])

        let acknowledged = try await gate.performReadCommand(name: "acknowledgedRetract") { writer in
            try writer.read { db in
                (
                    try OffloadRepo.hasLivePublishDelta(db, peer: "hq"),
                    try Int.fetchOne(
                        db,
                        sql: """
                        SELECT COUNT(*) FROM sync_ledger
                        WHERE session_id = 'retract-once'
                          AND remote_peer = 'hq' AND direction = 'out'
                        """
                    ) ?? 0
                )
            }
        }.value
        XCTAssertFalse(
            acknowledged.0,
            "a complete head that acknowledged the retraction must clear the scheduler delta"
        )
        XCTAssertEqual(acknowledged.1, 0)
    }

    func testFailedLiveHeadRetractionPreservesDelta_repro() async throws {
        let paths = try makePaths()
        defer { try? FileManager.default.removeItem(at: paths.runtime.deletingLastPathComponent()) }
        let gate = try ServiceWriterGate(databasePath: paths.database.path, runtimeDirectory: paths.runtime)
        _ = try await gate.performWriteCommand(name: "migrate") { try $0.migrate() }
        try await seedLocal(gate, id: "retry-retract", fts: ["must remain pending"])

        let inner = try LocalDirectoryBackend(root: paths.store)
        let backend = FailingHeadPutRemoteStorageBackend(
            inner: inner,
            headKey: LiveIngestKeys.head(peer: "hq")
        )
        let coordinator = RemoteSyncCoordinator(
            gate: gate,
            backend: backend,
            config: RemoteSyncConfig(
                enabled: true,
                storeRoot: paths.store,
                policy: OffloadPolicy(coldAgeDays: 90),
                offloadBatch: 20,
                rehydrateBatch: 20,
                vacuumFreelistThreshold: 1_000_000
            ),
            peer: "hq"
        )
        _ = try await coordinator.publishLivePeer(batch: 50, completeWalk: true)
        _ = try await gate.performWriteCommand(name: "makeIneligible") { writer in
            try writer.write { db in
                try db.execute(sql: "UPDATE sessions SET tier = 'skip' WHERE id = 'retry-retract'")
            }
        }
        await backend.arm()

        do {
            _ = try await coordinator.publishLivePeer(batch: 50, completeWalk: false)
            XCTFail("a failed live head PUT must fail the retraction")
        } catch {
            XCTAssertEqual(error as? EngramRemoteBackendError, .unexpectedStatus(503))
        }

        let pendingAfterFailure = try await gate.performReadCommand(name: "pendingAfterFailure") { writer in
            try writer.read { db in
                (
                    try OffloadRepo.hasLivePublishDelta(db, peer: "hq"),
                    try Int.fetchOne(
                        db,
                        sql: """
                        SELECT COUNT(*) FROM sync_ledger
                        WHERE session_id = 'retry-retract'
                          AND remote_peer = 'hq' AND direction = 'out'
                        """
                    ) ?? 0
                )
            }
        }.value
        XCTAssertTrue(pendingAfterFailure.0, "a failed head PUT must leave the retract delta retryable")
        XCTAssertEqual(pendingAfterFailure.1, 1)

        let oldHead = try ManifestCodec.decodeLiveHead(
            try await inner.get(key: LiveIngestKeys.head(peer: "hq"))
        )
        let oldManifest = try ManifestCodec.decodeLiveManifest(
            try await inner.get(key: oldHead.manifestKey)
        )
        XCTAssertEqual(oldManifest.entries.map(\.sessionId), ["retry-retract"])
    }

    func testEquivalentCompleteHeadRecoversRetractionAckAfterMetadataFailure_repro() async throws {
        let paths = try makePaths()
        defer { try? FileManager.default.removeItem(at: paths.runtime.deletingLastPathComponent()) }
        let (coordinator, gate, backend) = try makeCoordinatorSharedStore(
            paths, store: paths.store, peer: "hq"
        )
        _ = try await gate.performWriteCommand(name: "migrate") { try $0.migrate() }
        try await seedLocal(gate, id: "recover-retract", fts: ["published before crash"])

        let initial = try await coordinator.publishLivePeer(batch: 50, completeWalk: true)
        let initialManifestKey = LiveIngestKeys.manifest(
            peer: "hq",
            generation: initial.generation,
            seq: initial.seq
        )
        _ = try await gate.performWriteCommand(name: "makeIneligible") { writer in
            try writer.write { db in
                try db.execute(sql: "UPDATE sessions SET tier = 'skip' WHERE id = 'recover-retract'")
                try db.execute(
                    sql: "INSERT OR REPLACE INTO metadata(key, value) VALUES ('live_publish.hq.after_start', 'stale-start')"
                )
                try db.execute(
                    sql: "INSERT OR REPLACE INTO metadata(key, value) VALUES ('live_publish.hq.after_id', 'stale-id')"
                )
            }
        }

        // Model a process failure after the remote manifest/head PUTs succeeded
        // but before livePublishMeta could acknowledge the withdrawn membership.
        let recoveredGeneration = initial.generation + 1
        let recoveredSeq = initial.seq + 1
        let recoveredManifestKey = LiveIngestKeys.manifest(
            peer: "hq",
            generation: recoveredGeneration,
            seq: recoveredSeq
        )
        try await storeLiveSnapshot(
            backend: backend,
            sourcePeer: "hq",
            generation: recoveredGeneration,
            seq: recoveredSeq,
            artifacts: [],
            complete: true
        )
        let pendingBeforeRecovery = try await gate.performReadCommand(name: "pendingBeforeRecovery") { writer in
            try writer.read { db in try OffloadRepo.hasLivePublishDelta(db, peer: "hq") }
        }.value
        XCTAssertTrue(pendingBeforeRecovery)

        let recovered = try await coordinator.publishLivePeer(batch: 50, completeWalk: false)
        XCTAssertTrue(recovered.complete)
        XCTAssertEqual(recovered.publishedEntries, 0)
        XCTAssertEqual(recovered.generation, recoveredGeneration)
        XCTAssertEqual(recovered.seq, recoveredSeq)

        let acknowledged = try await gate.performReadCommand(name: "recoveredRetractAck") { writer in
            try writer.read { db in
                (
                    try OffloadRepo.hasLivePublishDelta(db, peer: "hq"),
                    try Int.fetchOne(
                        db,
                        sql: """
                        SELECT COUNT(*) FROM sync_ledger
                        WHERE session_id = 'recover-retract'
                          AND remote_peer = 'hq' AND direction = 'out'
                        """
                    ) ?? 0,
                    try String.fetchOne(
                        db,
                        sql: "SELECT value FROM metadata WHERE key = 'live_publish.hq.last_generation'"
                    ),
                    try String.fetchOne(
                        db,
                        sql: "SELECT value FROM metadata WHERE key = 'live_publish.hq.current_complete_key'"
                    ),
                    try String.fetchOne(
                        db,
                        sql: "SELECT value FROM metadata WHERE key = 'live_publish.hq.previous_complete_key'"
                    ),
                    try Int.fetchOne(
                        db,
                        sql: """
                        SELECT COUNT(*) FROM metadata
                        WHERE key IN ('live_publish.hq.after_start', 'live_publish.hq.after_id')
                        """
                    ) ?? 0
                )
            }
        }.value
        XCTAssertFalse(acknowledged.0)
        XCTAssertEqual(acknowledged.1, 0)
        XCTAssertEqual(acknowledged.2, String(recoveredGeneration))
        XCTAssertEqual(acknowledged.3, recoveredManifestKey)
        XCTAssertEqual(acknowledged.4, initialManifestKey)
        XCTAssertEqual(acknowledged.5, 0)

        _ = try await gate.performWriteCommand(name: "makeEligibleAgain") { writer in
            try writer.write { db in
                try db.execute(sql: "UPDATE sessions SET tier = 'normal' WHERE id = 'recover-retract'")
            }
        }
        let nextComplete = try await coordinator.publishLivePeer(batch: 50, completeWalk: true)
        XCTAssertTrue(nextComplete.complete)
        XCTAssertEqual(nextComplete.generation, recoveredGeneration + 1)
    }

    func testEquivalentCompleteHeadAcknowledgesCapturedRetractionAfterEligibilityRecovers_repro() async throws {
        let paths = try makePaths()
        defer { try? FileManager.default.removeItem(at: paths.runtime.deletingLastPathComponent()) }
        let gate = try ServiceWriterGate(databasePath: paths.database.path, runtimeDirectory: paths.runtime)
        _ = try await gate.performWriteCommand(name: "migrate") { try $0.migrate() }
        try await seedLocal(gate, id: "recover-before-finalize", fts: ["published before recovery"])

        let inner = try LocalDirectoryBackend(root: paths.store)
        let initialCoordinator = RemoteSyncCoordinator(
            gate: gate,
            backend: inner,
            config: RemoteSyncConfig(
                enabled: true,
                storeRoot: paths.store,
                policy: OffloadPolicy(coldAgeDays: 90),
                offloadBatch: 20,
                rehydrateBatch: 20,
                vacuumFreelistThreshold: 1_000_000
            ),
            peer: "hq"
        )
        let initial = try await initialCoordinator.publishLivePeer(batch: 50, completeWalk: true)
        let recoveredGeneration = initial.generation + 1
        let recoveredSeq = initial.seq + 1
        let recoveredManifestKey = LiveIngestKeys.manifest(
            peer: "hq",
            generation: recoveredGeneration,
            seq: recoveredSeq
        )

        _ = try await gate.performWriteCommand(name: "prepareRecoveredRetraction") { writer in
            try writer.write { db in
                try db.execute(
                    sql: "UPDATE sessions SET tier = 'skip' WHERE id = 'recover-before-finalize'"
                )
            }
        }
        try await storeLiveSnapshot(
            backend: inner,
            sourcePeer: "hq",
            generation: recoveredGeneration,
            seq: recoveredSeq,
            artifacts: [],
            complete: true
        )
        _ = try await gate.performWriteCommand(name: "alignRecoveredMetadataOnly") { writer in
            try writer.write { db in
                try db.execute(
                    sql: "INSERT OR REPLACE INTO metadata(key, value) VALUES ('live_publish.hq.last_generation', ?)",
                    arguments: [String(recoveredGeneration)]
                )
                try db.execute(
                    sql: "INSERT OR REPLACE INTO metadata(key, value) VALUES ('live_publish.hq.current_complete_key', ?)",
                    arguments: [recoveredManifestKey]
                )
                try db.execute(
                    sql: "DELETE FROM metadata WHERE key IN ('live_publish.hq.after_start', 'live_publish.hq.after_id')"
                )
            }
        }

        let backend = BeforeGetRemoteStorageBackend(
            inner: inner,
            triggerKey: recoveredManifestKey
        ) {
            _ = try await gate.performWriteCommand(name: "restoreEligibilityBeforeFinalize") { writer in
                try writer.write { db in
                    try db.execute(
                        sql: "UPDATE sessions SET tier = 'normal' WHERE id = 'recover-before-finalize'"
                    )
                }
            }
        }
        let coordinator = RemoteSyncCoordinator(
            gate: gate,
            backend: backend,
            config: RemoteSyncConfig(
                enabled: true,
                storeRoot: paths.store,
                policy: OffloadPolicy(coldAgeDays: 90),
                offloadBatch: 20,
                rehydrateBatch: 20,
                vacuumFreelistThreshold: 1_000_000
            ),
            peer: "hq"
        )

        let recovered = try await coordinator.publishLivePeer(batch: 50, completeWalk: false)
        XCTAssertTrue(recovered.complete)
        XCTAssertEqual(recovered.generation, recoveredGeneration)
        XCTAssertEqual(recovered.seq, recoveredSeq)

        let state = try await gate.performReadCommand(name: "verifyCapturedRetractionAck") { writer in
            try writer.read { db in
                (
                    try OffloadRepo.hasLivePublishDelta(db, peer: "hq"),
                    try Int.fetchOne(
                        db,
                        sql: """
                        SELECT COUNT(*) FROM sync_ledger
                        WHERE session_id = 'recover-before-finalize'
                          AND remote_peer = 'hq' AND direction = 'out'
                        """
                    ) ?? 0
                )
            }
        }.value
        XCTAssertTrue(
            state.0,
            "the row restored after assembly must become a new publish delta after the captured retract is acknowledged"
        )
        XCTAssertEqual(
            state.1,
            0,
            "an aligned metadata probe must still acknowledge a non-empty captured retract set"
        )
    }

    func testEquivalentCompleteHeadRecoversMetadataAndPreservesIncompleteCursor_repro() async throws {
        let paths = try makePaths()
        defer { try? FileManager.default.removeItem(at: paths.runtime.deletingLastPathComponent()) }
        let gate = try ServiceWriterGate(databasePath: paths.database.path, runtimeDirectory: paths.runtime)
        _ = try await gate.performWriteCommand(name: "migrate") { try $0.migrate() }
        try await seedLocal(gate, id: "cursor-ready", fts: ["stable cursor bundle"])
        try await seedLocal(gate, id: "recover-incomplete-retract", fts: ["withdrawn bundle"])

        let backend = try LocalDirectoryBackend(root: paths.store)
        let coordinator = RemoteSyncCoordinator(
            gate: gate,
            backend: backend,
            config: RemoteSyncConfig(
                enabled: true,
                storeRoot: paths.store,
                policy: OffloadPolicy(coldAgeDays: 90),
                offloadBatch: 20,
                rehydrateBatch: 20,
                vacuumFreelistThreshold: 1_000_000
            ),
            peer: "hq"
        )
        let initial = try await coordinator.publishLivePeer(batch: 50, completeWalk: true)
        let initialHead = try ManifestCodec.decodeLiveHead(
            try await backend.get(key: LiveIngestKeys.head(peer: "hq"))
        )
        let initialManifest = try ManifestCodec.decodeLiveManifest(
            try await backend.get(key: initialHead.manifestKey)
        )

        _ = try await gate.performWriteCommand(name: "prepareIncompleteRecovery") { writer in
            try writer.write { db in
                try db.execute(
                    sql: "UPDATE sessions SET tier = 'skip' WHERE id = 'recover-incomplete-retract'"
                )
                try db.execute(
                    sql: """
                    UPDATE sessions
                    SET sync_version = sync_version + 1,
                        snapshot_hash = 'cursor-ready-v2'
                    WHERE id = 'cursor-ready'
                    """
                )
            }
        }
        try await writeLiveSnapshot(
            gate,
            id: "unready-tail",
            snapshotHash: "unready-tail-v1",
            summary: "pending FTS keeps this sweep incomplete",
            startTime: "2024-01-02T00:00:00Z"
        )

        let recoveredGeneration = initial.generation + 1
        let recoveredSeq = initial.seq + 1
        let recoveredManifestKey = LiveIngestKeys.manifest(
            peer: "hq",
            generation: recoveredGeneration,
            seq: recoveredSeq
        )
        let recoveredManifest = SyncManifest(
            peer: "hq",
            updatedAt: "2026-08-30T00:00:00Z",
            entries: initialManifest.entries.filter { $0.sessionId == "cursor-ready" }
        )
        let recoveredManifestData = try ManifestCodec.encodeLiveManifest(recoveredManifest)
        try await backend.put(key: recoveredManifestKey, data: recoveredManifestData)
        try await backend.put(
            key: LiveIngestKeys.head(peer: "hq"),
            data: try ManifestCodec.encodeLiveHead(
                LiveIngestHead(
                    peer: "hq",
                    generation: recoveredGeneration,
                    seq: recoveredSeq,
                    complete: true,
                    entryCount: recoveredManifest.entries.count,
                    manifestKey: recoveredManifestKey,
                    contentHash: ManifestCodec.liveManifestContentHash(recoveredManifestData),
                    withdrawnCount: 1
                )
            )
        )

        let recovered = try await coordinator.publishLivePeer(batch: 50, completeWalk: false)
        XCTAssertFalse(recovered.complete, "the pending FTS job must keep the current sweep incomplete")
        XCTAssertEqual(recovered.generation, recoveredGeneration)
        XCTAssertEqual(recovered.seq, recoveredSeq)

        let state = try await gate.performReadCommand(name: "verifyIncompleteCompleteRecovery") { writer in
            try writer.read { db in
                (
                    try String.fetchOne(
                        db,
                        sql: "SELECT value FROM metadata WHERE key = 'live_publish.hq.last_generation'"
                    ),
                    try String.fetchOne(
                        db,
                        sql: "SELECT value FROM metadata WHERE key = 'live_publish.hq.current_complete_key'"
                    ),
                    try String.fetchOne(
                        db,
                        sql: "SELECT value FROM metadata WHERE key = 'live_publish.hq.previous_complete_key'"
                    ),
                    try String.fetchOne(
                        db,
                        sql: "SELECT value FROM metadata WHERE key = 'live_publish.hq.after_start'"
                    ),
                    try String.fetchOne(
                        db,
                        sql: "SELECT value FROM metadata WHERE key = 'live_publish.hq.after_id'"
                    ),
                    try Int.fetchOne(
                        db,
                        sql: """
                        SELECT COUNT(*) FROM sync_ledger
                        WHERE session_id = 'recover-incomplete-retract'
                          AND remote_peer = 'hq' AND direction = 'out'
                        """
                    ) ?? 0,
                    try String.fetchOne(
                        db,
                        sql: """
                        SELECT status FROM session_index_jobs
                        WHERE session_id = 'unready-tail' AND job_kind = 'fts'
                        """
                    )
                )
            }
        }.value
        XCTAssertEqual(state.0, String(recoveredGeneration))
        XCTAssertEqual(state.1, recoveredManifestKey)
        XCTAssertEqual(state.2, initialHead.manifestKey)
        XCTAssertEqual(state.3, "2024-01-01T00:00:00Z")
        XCTAssertEqual(state.4, "cursor-ready")
        XCTAssertEqual(state.5, 0)
        XCTAssertEqual(state.6, "pending")
    }

    func testCompletePublishPreservesBothEligibilityRacesUntilNextManifest_repro() async throws {
        let paths = try makePaths()
        defer { try? FileManager.default.removeItem(at: paths.runtime.deletingLastPathComponent()) }
        let gate = try ServiceWriterGate(databasePath: paths.database.path, runtimeDirectory: paths.runtime)
        _ = try await gate.performWriteCommand(name: "migrate") { try $0.migrate() }
        try await seedLocal(gate, id: "race-retained", fts: ["retained v1"])
        try await seedLocal(gate, id: "race-excluded", fts: ["excluded v1"])

        let inner = try LocalDirectoryBackend(root: paths.store)
        let baseCoordinator = RemoteSyncCoordinator(
            gate: gate,
            backend: inner,
            config: RemoteSyncConfig(
                enabled: true,
                storeRoot: paths.store,
                policy: OffloadPolicy(coldAgeDays: 90),
                offloadBatch: 20,
                rehydrateBatch: 20,
                vacuumFreelistThreshold: 1_000_000
            ),
            peer: "hq"
        )
        _ = try await baseCoordinator.publishLivePeer(batch: 50, completeWalk: true)

        _ = try await gate.performWriteCommand(name: "prepareEligibilityRace") { writer in
            try writer.write { db in
                try db.execute(sql: "DELETE FROM sessions_fts WHERE session_id = 'race-retained'")
                try db.execute(
                    sql: "INSERT INTO sessions_fts(session_id, content) VALUES ('race-retained', 'retained v2')"
                )
                try db.execute(
                    sql: """
                    UPDATE sessions
                    SET sync_version = sync_version + 1, snapshot_hash = 'race-retained-v2'
                    WHERE id = 'race-retained'
                    """
                )
                try db.execute(sql: "UPDATE sessions SET tier = 'skip' WHERE id = 'race-excluded'")
                for sessionId in ["race-retained", "race-excluded"] {
                    try db.execute(
                        sql: """
                        INSERT INTO sync_ledger(
                            session_id, remote_peer, remote_key, direction, content_hash
                        ) VALUES (?, 'other-peer', ?, 'out', ?)
                        """,
                        arguments: [sessionId, "other/\(sessionId).bundle", "other-\(sessionId)"]
                    )
                }
            }
        }

        let backend = BlockingLiveHeadPutRemoteStorageBackend(
            inner: inner,
            headKey: LiveIngestKeys.head(peer: "hq")
        )
        let coordinator = RemoteSyncCoordinator(
            gate: gate,
            backend: backend,
            config: RemoteSyncConfig(
                enabled: true,
                storeRoot: paths.store,
                policy: OffloadPolicy(coldAgeDays: 90),
                offloadBatch: 20,
                rehydrateBatch: 20,
                vacuumFreelistThreshold: 1_000_000
            ),
            peer: "hq"
        )
        let racedPublish = Task {
            try await coordinator.publishLivePeer(batch: 50, completeWalk: true)
        }
        await backend.waitUntilHeadPutIsBlocked()
        _ = try await gate.performWriteCommand(name: "flipEligibilityDuringHeadPut") { writer in
            try writer.write { db in
                try db.execute(sql: "UPDATE sessions SET tier = 'skip' WHERE id = 'race-retained'")
                try db.execute(sql: "UPDATE sessions SET tier = 'normal' WHERE id = 'race-excluded'")
            }
        }
        await backend.releaseHeadPut()
        let raced = try await racedPublish.value
        XCTAssertTrue(raced.complete)

        let racedHead = try ManifestCodec.decodeLiveHead(
            try await inner.get(key: LiveIngestKeys.head(peer: "hq"))
        )
        let racedManifest = try ManifestCodec.decodeLiveManifest(
            try await inner.get(key: racedHead.manifestKey)
        )
        XCTAssertEqual(racedManifest.entries.map(\.sessionId), ["race-retained"])

        let pending = try await gate.performReadCommand(name: "verifyEligibilityRacePending") { writer in
            try writer.read { db in
                (
                    try OffloadRepo.hasLivePublishDelta(db, peer: "hq"),
                    try Int.fetchOne(
                        db,
                        sql: """
                        SELECT COUNT(*) FROM sync_ledger
                        WHERE remote_peer = 'hq' AND direction = 'out'
                          AND session_id = 'race-retained'
                        """
                    ) ?? 0,
                    try Int.fetchOne(
                        db,
                        sql: """
                        SELECT COUNT(*) FROM sync_ledger
                        WHERE remote_peer = 'hq' AND direction = 'out'
                          AND session_id = 'race-excluded'
                        """
                    ) ?? 0,
                    try Int.fetchOne(
                        db,
                        sql: """
                        SELECT COUNT(*) FROM sync_ledger
                        WHERE remote_peer = 'other-peer' AND direction = 'out'
                        """
                    ) ?? 0
                )
            }
        }.value
        XCTAssertTrue(pending.0)
        XCTAssertEqual(pending.1, 1, "the retained manifest member must keep its ledger")
        XCTAssertEqual(pending.2, 0, "the excluded manifest member must lose only its HQ ledger")
        XCTAssertEqual(pending.3, 2, "ack must remain peer-isolated")

        let converged = try await coordinator.publishLivePeer(batch: 50, completeWalk: true)
        XCTAssertTrue(converged.complete)
        XCTAssertEqual(converged.generation, raced.generation + 1)
        let finalState = try await gate.performReadCommand(name: "verifyEligibilityRaceConverged") { writer in
            try writer.read { db in
                (
                    try OffloadRepo.hasLivePublishDelta(db, peer: "hq"),
                    try Int.fetchOne(
                        db,
                        sql: """
                        SELECT COUNT(*) FROM sync_ledger
                        WHERE remote_peer = 'hq' AND direction = 'out'
                          AND session_id = 'race-retained'
                        """
                    ) ?? 0,
                    try Int.fetchOne(
                        db,
                        sql: """
                        SELECT COUNT(*) FROM sync_ledger
                        WHERE remote_peer = 'hq' AND direction = 'out'
                          AND session_id = 'race-excluded'
                        """
                    ) ?? 0,
                    try Int.fetchOne(
                        db,
                        sql: """
                        SELECT COUNT(*) FROM sync_ledger
                        WHERE remote_peer = 'other-peer' AND direction = 'out'
                        """
                    ) ?? 0
                )
            }
        }.value
        XCTAssertFalse(finalState.0)
        XCTAssertEqual(finalState.1, 0)
        XCTAssertEqual(finalState.2, 1)
        XCTAssertEqual(finalState.3, 2)
    }

    func testLivePublishDoesNotConfirmSnapshotReindexedDuringNetworkWindow_repro() async throws {
        let paths = try makePaths()
        defer { try? FileManager.default.removeItem(at: paths.runtime.deletingLastPathComponent()) }
        let gate = try ServiceWriterGate(databasePath: paths.database.path, runtimeDirectory: paths.runtime)
        _ = try await gate.performWriteCommand(name: "migrate") { try $0.migrate() }
        try await seedLocal(gate, id: "network-window", fts: ["old network snapshot"])

        let inner = try LocalDirectoryBackend(root: paths.store)
        let backend = BlockingBundleHeadRemoteStorageBackend(inner: inner)
        let coordinator = RemoteSyncCoordinator(
            gate: gate,
            backend: backend,
            config: RemoteSyncConfig(
                enabled: true,
                storeRoot: paths.store,
                policy: OffloadPolicy(coldAgeDays: 90),
                offloadBatch: 20,
                rehydrateBatch: 20,
                vacuumFreelistThreshold: 1_000_000
            ),
            peer: "hq"
        )

        let firstPublish = Task {
            try await coordinator.publishLivePeer(batch: 50, completeWalk: true)
        }
        await backend.waitUntilBundleHeadIsBlocked()
        _ = try await gate.performWriteCommand(name: "reindexDuringLiveUpload") { writer in
            try writer.write { db in
                // Preserve the second-precision timestamp to reproduce an index
                // update that the timestamp-only currentness check cannot order.
                try db.execute(
                    sql: "DELETE FROM sessions_fts WHERE session_id = 'network-window'"
                )
                try db.execute(
                    sql: """
                    INSERT INTO sessions_fts(session_id, content)
                    VALUES ('network-window', 'new network snapshot')
                    """
                )
                try db.execute(
                    sql: """
                    UPDATE sessions
                    SET sync_version = sync_version + 1
                    WHERE id = 'network-window'
                    """
                )
            }
        }
        await backend.releaseBundleHead()
        _ = try await firstPublish.value

        let ledgerAfterStaleUpload = try await gate.performReadCommand(name: "staleLiveLedgerCheck") { writer in
            try writer.read { db in
                try Int.fetchOne(
                    db,
                    sql: """
                    SELECT COUNT(*) FROM sync_ledger
                    WHERE remote_peer = 'hq' AND direction = 'out'
                      AND session_id = 'network-window'
                    """
                ) ?? 0
            }
        }.value
        XCTAssertEqual(
            ledgerAfterStaleUpload,
            0,
            "an upload from a stale local snapshot must not be confirmed in the peer ledger"
        )

        _ = try await coordinator.publishLivePeer(batch: 50, completeWalk: false)
        let head = try ManifestCodec.decodeLiveHead(
            try await inner.get(key: LiveIngestKeys.head(peer: "hq"))
        )
        let manifest = try ManifestCodec.decodeLiveManifest(
            try await inner.get(key: head.manifestKey)
        )
        let entry = try XCTUnwrap(manifest.entries.first { $0.sessionId == "network-window" })
        let bundle = try BundleCodec.decode(
            try await inner.get(key: entry.remoteKey),
            expectedSessionId: "network-window"
        )
        XCTAssertEqual(bundle.ftsContents, ["new network snapshot"])
    }

    func testLivePublishWaitsForRunnerFtsPhaseBeforeConfirmingSnapshot_repro() async throws {
        let paths = try makePaths()
        defer { try? FileManager.default.removeItem(at: paths.runtime.deletingLastPathComponent()) }
        let gate = try ServiceWriterGate(databasePath: paths.database.path, runtimeDirectory: paths.runtime)
        _ = try await gate.performWriteCommand(name: "migrate") { try $0.migrate() }
        try await seedLocal(gate, id: "runner-two-phase", fts: ["old runner snapshot"])

        let inner = try LocalDirectoryBackend(root: paths.store)
        let backend = RecordingRemoteStorageBackend(inner: inner)
        let coordinator = RemoteSyncCoordinator(
            gate: gate,
            backend: backend,
            config: RemoteSyncConfig(
                enabled: true,
                storeRoot: paths.store,
                policy: OffloadPolicy(coldAgeDays: 90),
                offloadBatch: 20,
                rehydrateBatch: 20,
                vacuumFreelistThreshold: 1_000_000
            ),
            peer: "hq"
        )

        let initial = try await coordinator.publishLivePeer(batch: 50, completeWalk: true)
        XCTAssertEqual(initial.uploaded, 1)
        XCTAssertTrue(initial.complete)

        // Match the service runner's two commands: indexRecent advances the
        // session and enqueues FTS work, then periodicFtsDrain runs later.
        _ = try await gate.performWriteCommand(name: "indexRecent") { writer in
            try writer.write { db in
                try SessionSnapshotWriter(db: db).writeAuthoritativeSnapshot(
                    AuthoritativeSessionSnapshot(
                        id: "runner-two-phase",
                        source: .codex,
                        authoritativeNode: "",
                        syncVersion: 1,
                        snapshotHash: "runner-two-phase-v1",
                        indexedAt: "2026-08-30T12:00:00Z",
                        sourceLocator: "/tmp/runner-two-phase.jsonl",
                        sizeBytes: 8192,
                        startTime: "2024-01-01T00:00:00Z",
                        endTime: "2024-01-01T01:00:01Z",
                        cwd: "/Users/bing/-Code-/demo",
                        project: "demo",
                        messageCount: 3,
                        userMessageCount: 2,
                        assistantMessageCount: 1,
                        toolMessageCount: 0,
                        systemMessageCount: 0,
                        summary: "new runner summary",
                        summaryMessageCount: 3,
                        origin: "local",
                        tier: .normal
                    )
                )
            }
        }
        _ = try await gate.performReadCommand(name: "verifyRunnerStageOne") { writer in
            try writer.read { db in
                XCTAssertEqual(
                    try String.fetchAll(
                        db,
                        sql: "SELECT content FROM sessions_fts WHERE session_id = 'runner-two-phase' ORDER BY rowid"
                    ),
                    ["old runner snapshot"]
                )
                XCTAssertEqual(
                    try String.fetchOne(
                        db,
                        sql: "SELECT status FROM session_index_jobs WHERE session_id = 'runner-two-phase' AND job_kind = 'fts'"
                    ),
                    "pending"
                )
            }
        }

        let betweenPhases = try await coordinator.publishLivePeer(batch: 50, completeWalk: false)
        XCTAssertFalse(betweenPhases.complete)
        let ledgerVersionBetweenPhases = try await gate.performReadCommand(name: "verifyRunnerFence") { writer in
            try writer.read { db in
                try Int.fetchOne(
                    db,
                    sql: """
                    SELECT source_sync_version FROM sync_ledger
                    WHERE remote_peer = 'hq' AND direction = 'out'
                      AND session_id = 'runner-two-phase'
                    ORDER BY synced_at DESC, id DESC LIMIT 1
                    """
                )
            }
        }.value
        XCTAssertEqual(
            ledgerVersionBetweenPhases,
            0,
            "stage-one session metadata must not certify the still-old FTS snapshot"
        )

        let adapter = RunnerTwoPhaseFTSAdapter(contents: ["new runner snapshot"])
        _ = try await gate.performWriteCommand(name: "periodicFtsDrain") { writer in
            try await IndexJobRunner(writer: writer, adapters: [adapter]).runRecoverableJobs()
        }
        _ = try await gate.performReadCommand(name: "verifyRunnerFtsComplete") { writer in
            try writer.read { db in
                XCTAssertEqual(
                    try String.fetchOne(
                        db,
                        sql: "SELECT status FROM session_index_jobs WHERE session_id = 'runner-two-phase' AND job_kind = 'fts'"
                    ),
                    "completed"
                )
            }
        }

        await backend.resetObservations()
        let afterFts = try await coordinator.publishLivePeer(batch: 50, completeWalk: false)
        XCTAssertEqual(afterFts.uploaded, 1, "the next steady-state cycle must publish completed FTS")
        let head = try ManifestCodec.decodeLiveHead(
            try await inner.get(key: LiveIngestKeys.head(peer: "hq"))
        )
        let manifest = try ManifestCodec.decodeLiveManifest(
            try await inner.get(key: head.manifestKey)
        )
        let entry = try XCTUnwrap(manifest.entries.first { $0.sessionId == "runner-two-phase" })
        let bundle = try BundleCodec.decode(
            try await inner.get(key: entry.remoteKey),
            expectedSessionId: "runner-two-phase"
        )
        XCTAssertTrue(bundle.ftsContents.contains("new runner snapshot"))
        XCTAssertFalse(bundle.ftsContents.contains("old runner snapshot"))

        _ = try await gate.performWriteCommand(name: "installRunnerFtsReadTrap") { writer in
            try writer.write { db in try db.execute(sql: "DROP TABLE sessions_fts") }
        }
        await backend.resetObservations()
        let generationBefore = await gate.currentDatabaseGeneration()
        let unchanged = try await coordinator.publishLivePeer(batch: 50, completeWalk: false)
        XCTAssertEqual(unchanged.uploaded, 0)
        XCTAssertEqual(unchanged.generation, afterFts.generation)
        XCTAssertEqual(unchanged.seq, afterFts.seq)
        let observations = await backend.observations()
        XCTAssertEqual(observations.headKeys, [])
        XCTAssertEqual(observations.putKeys, [])
        let generationAfter = await gate.currentDatabaseGeneration()
        XCTAssertEqual(generationAfter, generationBefore)
    }

    func testLivePublishFencesSameVersionSnapshotChangedDuringNetworkWindow_repro() async throws {
        let paths = try makePaths()
        defer { try? FileManager.default.removeItem(at: paths.runtime.deletingLastPathComponent()) }
        let gate = try ServiceWriterGate(databasePath: paths.database.path, runtimeDirectory: paths.runtime)
        _ = try await gate.performWriteCommand(name: "migrate") { try $0.migrate() }
        try await writeLiveSnapshot(
            gate,
            id: "same-version-window",
            snapshotHash: "same-version-v1",
            summary: "old same-version summary"
        )
        try await drainLiveFts(gate, contents: ["old same-version FTS"])

        let inner = try LocalDirectoryBackend(root: paths.store)
        let blockingBackend = BlockingBundleHeadRemoteStorageBackend(inner: inner)
        let coordinator = RemoteSyncCoordinator(
            gate: gate,
            backend: blockingBackend,
            config: RemoteSyncConfig(
                enabled: true,
                storeRoot: paths.store,
                policy: OffloadPolicy(coldAgeDays: 90),
                offloadBatch: 20,
                rehydrateBatch: 20,
                vacuumFreelistThreshold: 1_000_000
            ),
            peer: "hq"
        )

        let stalePublish = Task {
            try await coordinator.publishLivePeer(batch: 50, completeWalk: false)
        }
        var reachedNetworkWindow = false
        for _ in 0..<200 {
            if await blockingBackend.bundleHeadIsBlocked() {
                reachedNetworkWindow = true
                break
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(reachedNetworkWindow, "the real v1 bundle must reach the blocked network HEAD")
        guard reachedNetworkWindow else {
            stalePublish.cancel()
            await blockingBackend.releaseBundleHead()
            _ = try? await stalePublish.value
            return
        }

        // The production Swift indexer keeps syncVersion at 1. Complete both
        // runner phases while the v1 network result is still in flight.
        try await writeLiveSnapshot(
            gate,
            id: "same-version-window",
            snapshotHash: "same-version-v2",
            summary: "new same-version summary"
        )
        try await drainLiveFts(gate, contents: ["new same-version FTS"])
        _ = try await gate.performReadCommand(name: "verifySameVersionReindex") { writer in
            try writer.read { db in
                XCTAssertEqual(
                    try Int.fetchOne(db, sql: "SELECT sync_version FROM sessions WHERE id = 'same-version-window'"),
                    1
                )
                XCTAssertEqual(
                    try String.fetchOne(db, sql: "SELECT snapshot_hash FROM sessions WHERE id = 'same-version-window'"),
                    "same-version-v2"
                )
                XCTAssertEqual(
                    try String.fetchOne(
                        db,
                        sql: "SELECT status FROM session_index_jobs WHERE session_id = 'same-version-window' AND job_kind = 'fts'"
                    ),
                    "completed"
                )
                XCTAssertEqual(
                    try String.fetchAll(
                        db,
                        sql: "SELECT content FROM sessions_fts WHERE session_id = 'same-version-window' ORDER BY rowid"
                    ),
                    ["new same-version FTS", "old same-version summary"]
                )
            }
        }

        await blockingBackend.releaseBundleHead()
        let staleResult = try await stalePublish.value
        XCTAssertFalse(staleResult.complete)
        let staleLedgerCount = try await gate.performReadCommand(name: "verifySameVersionStaleLedger") { writer in
            try writer.read { db in
                try Int.fetchOne(
                    db,
                    sql: """
                    SELECT COUNT(*) FROM sync_ledger
                    WHERE remote_peer = 'hq' AND direction = 'out'
                      AND session_id = 'same-version-window'
                    """
                ) ?? 0
            }
        }.value
        XCTAssertEqual(
            staleLedgerCount,
            0,
            "a v1 network result must not certify the completed v2 snapshot when both use syncVersion=1"
        )

        let recordingBackend = RecordingRemoteStorageBackend(inner: inner)
        let steadyCoordinator = RemoteSyncCoordinator(
            gate: gate,
            backend: recordingBackend,
            config: RemoteSyncConfig(
                enabled: true,
                storeRoot: paths.store,
                policy: OffloadPolicy(coldAgeDays: 90),
                offloadBatch: 20,
                rehydrateBatch: 20,
                vacuumFreelistThreshold: 1_000_000
            ),
            peer: "hq"
        )
        let afterFts = try await steadyCoordinator.publishLivePeer(batch: 50, completeWalk: false)
        XCTAssertEqual(afterFts.uploaded, 1, "the next steady cycle must publish the completed v2 FTS")
        XCTAssertTrue(afterFts.complete)

        let head = try ManifestCodec.decodeLiveHead(
            try await inner.get(key: LiveIngestKeys.head(peer: "hq"))
        )
        let manifest = try ManifestCodec.decodeLiveManifest(
            try await inner.get(key: head.manifestKey)
        )
        let entry = try XCTUnwrap(manifest.entries.first { $0.sessionId == "same-version-window" })
        let bundle = try BundleCodec.decode(
            try await inner.get(key: entry.remoteKey),
            expectedSessionId: "same-version-window"
        )
        XCTAssertEqual(bundle.ftsContents, ["new same-version FTS", "old same-version summary"])

        let ledgerFence = try await gate.performReadCommand(name: "verifySameVersionLedgerFence") { writer in
            try writer.read { db -> (Int?, String?) in
                let columns = Set(
                    try String.fetchAll(db, sql: "SELECT name FROM pragma_table_info('sync_ledger')")
                )
                let sourceHash = columns.contains("source_snapshot_hash")
                    ? try String.fetchOne(
                        db,
                        sql: """
                        SELECT source_snapshot_hash FROM sync_ledger
                        WHERE remote_peer = 'hq' AND direction = 'out'
                          AND session_id = 'same-version-window'
                        ORDER BY synced_at DESC, id DESC LIMIT 1
                        """
                    )
                    : nil
                let sourceVersion = try Int.fetchOne(
                    db,
                    sql: """
                    SELECT source_sync_version FROM sync_ledger
                    WHERE remote_peer = 'hq' AND direction = 'out'
                      AND session_id = 'same-version-window'
                    ORDER BY synced_at DESC, id DESC LIMIT 1
                    """
                )
                return (sourceVersion, sourceHash)
            }
        }.value
        XCTAssertEqual(ledgerFence.0, 1)
        XCTAssertEqual(ledgerFence.1, "same-version-v2")

        _ = try await gate.performWriteCommand(name: "installSameVersionFtsReadTrap") { writer in
            try writer.write { db in try db.execute(sql: "DROP TABLE sessions_fts") }
        }
        await recordingBackend.resetObservations()
        let generationBefore = await gate.currentDatabaseGeneration()
        let unchanged = try await steadyCoordinator.publishLivePeer(batch: 50, completeWalk: false)
        XCTAssertEqual(unchanged.uploaded, 0)
        XCTAssertEqual(unchanged.generation, afterFts.generation)
        XCTAssertEqual(unchanged.seq, afterFts.seq)
        let observations = await recordingBackend.observations()
        XCTAssertEqual(observations.headKeys, [])
        XCTAssertEqual(observations.putKeys, [])
        let generationAfter = await gate.currentDatabaseGeneration()
        XCTAssertEqual(generationAfter, generationBefore)
    }

    func testSteadyLivePublishSkipsUnreadyPrefixAndPublishesReadyTail_repro() async throws {
        let paths = try makePaths()
        defer { try? FileManager.default.removeItem(at: paths.runtime.deletingLastPathComponent()) }
        let gate = try ServiceWriterGate(databasePath: paths.database.path, runtimeDirectory: paths.runtime)
        _ = try await gate.performWriteCommand(name: "migrate") { try $0.migrate() }

        try await writeLiveSnapshot(
            gate,
            id: "retained",
            snapshotHash: "retained-v1",
            summary: "retained v1",
            startTime: "2023-01-01T00:00:00Z"
        )
        try await drainLiveFts(gate, contents: ["retained old FTS"])

        let inner = try LocalDirectoryBackend(root: paths.store)
        let backend = RecordingRemoteStorageBackend(inner: inner)
        let coordinator = RemoteSyncCoordinator(
            gate: gate,
            backend: backend,
            config: RemoteSyncConfig(
                enabled: true,
                storeRoot: paths.store,
                policy: OffloadPolicy(coldAgeDays: 90),
                offloadBatch: 20,
                rehydrateBatch: 20,
                vacuumFreelistThreshold: 1_000_000
            ),
            peer: "hq"
        )
        let baseline = try await coordinator.publishLivePeer(batch: 50, completeWalk: true)
        XCTAssertTrue(baseline.complete)
        let baselineHead = try ManifestCodec.decodeLiveHead(
            try await inner.get(key: LiveIngestKeys.head(peer: "hq"))
        )
        let baselineManifestData = try await inner.get(key: baselineHead.manifestKey)

        try await writeLiveSnapshot(
            gate,
            id: "ready-tail",
            snapshotHash: "ready-tail-v1",
            summary: "ready tail",
            startTime: "2025-01-01T00:00:00Z"
        )
        try await drainLiveFts(gate, contents: ["ready tail FTS"])

        // Fill the complete steady-state page with earlier, not-ready rows.
        // The retained row already has a published ledger entry, so keeping the
        // resulting head incomplete also protects it from false retraction.
        try await writeLiveSnapshot(
            gate,
            id: "retained",
            snapshotHash: "retained-v2",
            summary: "retained v2 pending",
            startTime: "2023-01-01T00:00:00Z"
        )
        try await writeLiveSnapshot(
            gate,
            id: "blocked-1",
            snapshotHash: "blocked-1-v1",
            summary: "blocked one",
            startTime: "2023-01-02T00:00:00Z"
        )
        try await writeLiveSnapshot(
            gate,
            id: "blocked-2",
            snapshotHash: "blocked-2-v1",
            summary: "blocked two",
            startTime: "2023-01-03T00:00:00Z"
        )
        _ = try await gate.performReadCommand(name: "verifyUnreadyPrefix") { writer in
            try writer.read { db in
                XCTAssertEqual(
                    try Int.fetchOne(
                        db,
                        sql: """
                        SELECT COUNT(*) FROM session_index_jobs
                        WHERE session_id IN ('retained', 'blocked-1', 'blocked-2')
                          AND job_kind = 'fts' AND status = 'pending'
                        """
                    ),
                    3
                )
            }
        }

        await backend.resetObservations()
        let steady = try await coordinator.publishLivePeer(batch: 3, completeWalk: false)
        XCTAssertEqual(
            steady.uploaded,
            1,
            "three older unready rows must not starve the ready tail from the first steady page"
        )
        XCTAssertFalse(steady.complete, "unready local snapshots must keep the published head incomplete")

        let observations = await backend.observations()
        XCTAssertEqual(observations.headKeys.filter { $0.hasSuffix(".bundle") }.count, 1)
        XCTAssertEqual(observations.putKeys.filter { $0.hasSuffix(".bundle") }.count, 1)

        let head = try ManifestCodec.decodeLiveHead(
            try await inner.get(key: LiveIngestKeys.head(peer: "hq"))
        )
        XCTAssertFalse(head.complete)
        XCTAssertEqual(head.withdrawnCount, 0)
        let manifest = try ManifestCodec.decodeLiveManifest(
            try await inner.get(key: head.manifestKey)
        )
        XCTAssertEqual(Set(manifest.entries.map(\.sessionId)), ["retained", "ready-tail"])
        let tailEntry = try XCTUnwrap(manifest.entries.first { $0.sessionId == "ready-tail" })
        let tailBundle = try BundleCodec.decode(
            try await inner.get(key: tailEntry.remoteKey),
            expectedSessionId: "ready-tail"
        )
        XCTAssertEqual(tailBundle.ftsContents, ["ready tail FTS", "ready tail"])
        let preservedBaselineManifestData = try await inner.get(key: baselineHead.manifestKey)
        XCTAssertEqual(
            preservedBaselineManifestData,
            baselineManifestData,
            "the prior complete manifest must remain available while unready snapshots block completion"
        )
    }

    func testLivePublishContinuesWhenPreviousCompleteManifestIsMissing_repro() async throws {
        let paths = try makePaths()
        defer { try? FileManager.default.removeItem(at: paths.runtime.deletingLastPathComponent()) }
        let (coordinator, gate, backend) = try makeCoordinatorSharedStore(
            paths, store: paths.store, peer: "hq"
        )
        _ = try await gate.performWriteCommand(name: "migrate") { try $0.migrate() }
        try await seedLocal(gate, id: "original", fts: ["original"])

        let first = try await coordinator.publishLivePeer(batch: 50, completeWalk: true)
        XCTAssertTrue(first.complete)
        let firstManifestKey = LiveIngestKeys.manifest(
            peer: "hq", generation: first.generation, seq: first.seq
        )

        try await seedLocal(gate, id: "new-1", fts: ["new one"])
        try await seedLocal(gate, id: "new-2", fts: ["new two"])
        let incremental = try await coordinator.publishLivePeer(batch: 1, completeWalk: false)
        XCTAssertFalse(incremental.complete)
        try await backend.delete(key: firstManifestKey)

        let recovered = try await coordinator.publishLivePeer(batch: 50, completeWalk: true)

        XCTAssertTrue(recovered.complete)
        XCTAssertEqual(recovered.publishedEntries, 3)
        let head = try ManifestCodec.decodeLiveHead(
            try await backend.get(key: LiveIngestKeys.head(peer: "hq"))
        )
        XCTAssertEqual(head.withdrawnCount, 0)
    }

    func testLivePublishRecordsGeneralFailure_repro() async throws {
        let paths = try makePaths()
        defer { try? FileManager.default.removeItem(at: paths.runtime.deletingLastPathComponent()) }
        let gate = try ServiceWriterGate(databasePath: paths.database.path, runtimeDirectory: paths.runtime)
        _ = try await gate.performWriteCommand(name: "migrate") { try $0.migrate() }
        let inner = try LocalDirectoryBackend(root: paths.store)
        let backend = FailingGetBackend(inner: inner, failKeySubstring: LiveIngestKeys.head(peer: "hq"))
        await backend.arm()
        let coordinator = RemoteSyncCoordinator(
            gate: gate,
            backend: backend,
            config: RemoteSyncConfig(
                enabled: true,
                storeRoot: paths.store,
                policy: OffloadPolicy(coldAgeDays: 90),
                offloadBatch: 20,
                rehydrateBatch: 20,
                vacuumFreelistThreshold: 1_000_000
            ),
            peer: "hq"
        )

        do {
            _ = try await coordinator.publishLivePeer()
            XCTFail("a general publish failure must propagate")
        } catch {
            XCTAssertEqual(error as? EngramRemoteBackendError, .unexpectedStatus(503))
        }
        try await assertLivePullError(gate: gate, peer: "hq", expected: "publish_failed")
    }

    func testLivePullRecordsGeneralFailure_repro() async throws {
        let paths = try makePaths()
        defer { try? FileManager.default.removeItem(at: paths.runtime.deletingLastPathComponent()) }
        let gate = try ServiceWriterGate(databasePath: paths.database.path, runtimeDirectory: paths.runtime)
        _ = try await gate.performWriteCommand(name: "migrate") { try $0.migrate() }
        let inner = try LocalDirectoryBackend(root: paths.store)
        let backend = FailingGetBackend(inner: inner, failKeySubstring: LiveIngestKeys.head(peer: "hq"))
        await backend.arm()
        let coordinator = RemoteSyncCoordinator(
            gate: gate,
            backend: backend,
            config: RemoteSyncConfig(
                enabled: true,
                storeRoot: paths.store,
                policy: OffloadPolicy(coldAgeDays: 90),
                offloadBatch: 20,
                rehydrateBatch: 20,
                vacuumFreelistThreshold: 1_000_000
            ),
            peer: "mac"
        )

        do {
            _ = try await coordinator.pullLivePeer(peer: "hq")
            XCTFail("a general pull failure must propagate")
        } catch {
            XCTAssertEqual(error as? EngramRemoteBackendError, .unexpectedStatus(503))
        }
        try await assertLivePullError(gate: gate, peer: "hq", expected: "pull_failed")
    }

    func testLivePullRejectsOlderGenerationBeforeImport_repro() async throws {
        let paths = try makePaths()
        defer { try? FileManager.default.removeItem(at: paths.runtime.deletingLastPathComponent()) }
        let (coordinator, gate, backend) = try makeCoordinatorSharedStore(
            paths, store: paths.store, peer: "mac"
        )
        _ = try await gate.performWriteCommand(name: "migrate") { try $0.migrate() }

        let current = makeLiveArtifact(sessionId: "current", text: "current generation")
        try await storeLiveSnapshot(
            backend: backend,
            sourcePeer: "hq",
            generation: 2,
            seq: 2,
            artifacts: [current]
        )
        let initialPull = try await coordinator.pullLivePeer(peer: "hq")
        XCTAssertEqual(initialPull.imported, 1)

        let stale = makeLiveArtifact(sessionId: "stale", text: "stale replay")
        try await storeLiveSnapshot(
            backend: backend,
            sourcePeer: "hq",
            generation: 1,
            seq: 3,
            artifacts: [stale]
        )
        let replay = try await coordinator.pullLivePeer(peer: "hq")

        XCTAssertEqual(replay.imported, 0)
        XCTAssertEqual(replay.retracted, 0)
        _ = try await gate.performReadCommand(name: "verifyGenerationFence") { writer in
            try writer.read { db in
                XCTAssertNotNil(
                    try String.fetchOne(
                        db,
                        sql: "SELECT id FROM sessions WHERE id = ?",
                        arguments: [ImportRepo.importedLocalId(peer: "hq", sessionId: "current")]
                    )
                )
                XCTAssertNil(
                    try String.fetchOne(
                        db,
                        sql: "SELECT id FROM sessions WHERE id = ?",
                        arguments: [ImportRepo.importedLocalId(peer: "hq", sessionId: "stale")]
                    )
                )
                XCTAssertEqual(
                    try String.fetchOne(
                        db,
                        sql: "SELECT value FROM metadata WHERE key = 'live_ingest.hq.last_error'"
                    ),
                    "stale_generation"
                )
            }
        }
    }

    func testLivePullRejectsOlderSeqWithinSameGenerationBeforeRetract_repro() async throws {
        let paths = try makePaths()
        defer { try? FileManager.default.removeItem(at: paths.runtime.deletingLastPathComponent()) }
        let (coordinator, gate, backend) = try makeCoordinatorSharedStore(
            paths, store: paths.store, peer: "mac"
        )
        _ = try await gate.performWriteCommand(name: "migrate") { try $0.migrate() }

        let first = makeLiveArtifact(sessionId: "first", text: "first")
        let later = makeLiveArtifact(sessionId: "later", text: "later")
        try await storeLiveSnapshot(
            backend: backend,
            sourcePeer: "hq",
            generation: 1,
            seq: 10,
            artifacts: [first]
        )
        let initial = try await coordinator.pullLivePeer(peer: "hq")
        XCTAssertEqual(initial.imported, 1)

        try await storeLiveSnapshot(
            backend: backend,
            sourcePeer: "hq",
            generation: 1,
            seq: 11,
            artifacts: [first, later],
            complete: false
        )
        let newerIncomplete = try await coordinator.pullLivePeer(peer: "hq")
        XCTAssertEqual(newerIncomplete.imported, 1)
        XCTAssertEqual(newerIncomplete.retracted, 0)

        try await storeLiveSnapshot(
            backend: backend,
            sourcePeer: "hq",
            generation: 1,
            seq: 10,
            artifacts: [first]
        )
        let replay = try await coordinator.pullLivePeer(peer: "hq")

        XCTAssertEqual(replay.imported, 0)
        XCTAssertEqual(replay.retracted, 0)
        _ = try await gate.performReadCommand(name: "verifySequenceFence") { writer in
            try writer.read { db in
                XCTAssertNotNil(
                    try String.fetchOne(
                        db,
                        sql: "SELECT id FROM sessions WHERE id = ?",
                        arguments: [ImportRepo.importedLocalId(peer: "hq", sessionId: "later")]
                    )
                )
                XCTAssertEqual(
                    try String.fetchOne(
                        db,
                        sql: "SELECT value FROM metadata WHERE key = 'live_ingest.hq.last_generation'"
                    ),
                    "1"
                )
                XCTAssertEqual(
                    try String.fetchOne(
                        db,
                        sql: "SELECT value FROM metadata WHERE key = 'live_ingest.hq.last_seq'"
                    ),
                    "11"
                )
                XCTAssertEqual(
                    try String.fetchOne(
                        db,
                        sql: "SELECT value FROM metadata WHERE key = 'live_ingest.hq.last_error'"
                    ),
                    "stale_generation"
                )
            }
        }
    }

    func testLivePullRechecksNativeOccupancyInsideCommit_repro() async throws {
        let paths = try makePaths()
        defer { try? FileManager.default.removeItem(at: paths.runtime.deletingLastPathComponent()) }
        let gate = try ServiceWriterGate(databasePath: paths.database.path, runtimeDirectory: paths.runtime)
        _ = try await gate.performWriteCommand(name: "migrate") { try $0.migrate() }
        let inner = try LocalDirectoryBackend(root: paths.store)
        let artifact = makeLiveArtifact(sessionId: "raced", text: "remote candidate")
        try await storeLiveSnapshot(
            backend: inner,
            sourcePeer: "hq",
            generation: 1,
            seq: 1,
            artifacts: [artifact]
        )
        let backend = BeforeGetRemoteStorageBackend(
            inner: inner,
            triggerKey: artifact.entry.remoteKey
        ) {
            _ = try await gate.performWriteCommand(name: "winNativeOccupancyRace") { writer in
                try writer.write { db in
                    try db.execute(
                        sql: """
                        INSERT INTO sessions(id, source, start_time, file_path, origin)
                        VALUES ('raced', 'codex', '2026-08-30T00:00:00Z', '/tmp/raced.jsonl', 'local')
                        """
                    )
                }
            }
        }
        let coordinator = RemoteSyncCoordinator(
            gate: gate,
            backend: backend,
            config: RemoteSyncConfig(
                enabled: true,
                storeRoot: paths.store,
                policy: OffloadPolicy(coldAgeDays: 90),
                offloadBatch: 20,
                rehydrateBatch: 20,
                vacuumFreelistThreshold: 1_000_000
            ),
            peer: "mac"
        )

        let result = try await coordinator.pullLivePeer(peer: "hq")

        XCTAssertEqual(result.imported, 0)
        XCTAssertEqual(result.occupancySkipped, 1)
        _ = try await gate.performReadCommand(name: "verifyOccupancyRace") { writer in
            try writer.read { db in
                XCTAssertEqual(
                    try String.fetchOne(db, sql: "SELECT origin FROM sessions WHERE id = 'raced'"),
                    "local"
                )
                XCTAssertNil(
                    try String.fetchOne(
                        db,
                        sql: "SELECT id FROM sessions WHERE id = ?",
                        arguments: [ImportRepo.importedLocalId(peer: "hq", sessionId: "raced")]
                    )
                )
            }
        }
    }

    func testLivePullRejectsMismatchedHeadPeerAndRecordsError_repro() async throws {
        let paths = try makePaths()
        defer { try? FileManager.default.removeItem(at: paths.runtime.deletingLastPathComponent()) }
        let (coordinator, gate, backend) = try makeCoordinatorSharedStore(
            paths, store: paths.store, peer: "mac"
        )
        _ = try await gate.performWriteCommand(name: "migrate") { try $0.migrate() }
        let artifact = makeLiveArtifact(sessionId: "forged-head", text: "forged")
        try await storeLiveSnapshot(
            backend: backend,
            sourcePeer: "hq",
            generation: 1,
            seq: 1,
            artifacts: [artifact],
            headPeer: "other"
        )

        do {
            _ = try await coordinator.pullLivePeer(peer: "hq")
            XCTFail("head peer mismatch must fail closed")
        } catch {
            XCTAssertEqual(error as? RemoteSyncError, .livePeerMismatch(expected: "hq", actual: "other"))
        }
        try await assertLivePullError(gate: gate, peer: "hq", expected: "head_peer_mismatch")
    }

    func testLivePullRejectsCrossPeerManifestKeyAndRecordsError_repro() async throws {
        let paths = try makePaths()
        defer { try? FileManager.default.removeItem(at: paths.runtime.deletingLastPathComponent()) }
        let (coordinator, gate, backend) = try makeCoordinatorSharedStore(
            paths, store: paths.store, peer: "mac"
        )
        _ = try await gate.performWriteCommand(name: "migrate") { try $0.migrate() }
        let artifact = makeLiveArtifact(sessionId: "forged-key", text: "forged")
        let wrongKey = LiveIngestKeys.manifest(peer: "other", generation: 1, seq: 1)
        try await storeLiveSnapshot(
            backend: backend,
            sourcePeer: "hq",
            generation: 1,
            seq: 1,
            artifacts: [artifact],
            manifestKey: wrongKey
        )

        do {
            _ = try await coordinator.pullLivePeer(peer: "hq")
            XCTFail("cross-peer manifest key must fail closed")
        } catch {
            XCTAssertEqual(
                error as? RemoteSyncError,
                .liveManifestKeyMismatch(
                    expected: LiveIngestKeys.manifest(peer: "hq", generation: 1, seq: 1),
                    actual: wrongKey
                )
            )
        }
        try await assertLivePullError(gate: gate, peer: "hq", expected: "manifest_key_mismatch")
    }

    func testLivePullRejectsMismatchedManifestPeerAndRecordsError_repro() async throws {
        let paths = try makePaths()
        defer { try? FileManager.default.removeItem(at: paths.runtime.deletingLastPathComponent()) }
        let (coordinator, gate, backend) = try makeCoordinatorSharedStore(
            paths, store: paths.store, peer: "mac"
        )
        _ = try await gate.performWriteCommand(name: "migrate") { try $0.migrate() }
        let artifact = makeLiveArtifact(sessionId: "forged-manifest", text: "forged")
        try await storeLiveSnapshot(
            backend: backend,
            sourcePeer: "hq",
            generation: 1,
            seq: 1,
            artifacts: [artifact],
            manifestPeer: "other"
        )

        do {
            _ = try await coordinator.pullLivePeer(peer: "hq")
            XCTFail("manifest peer mismatch must fail closed")
        } catch {
            XCTAssertEqual(error as? RemoteSyncError, .livePeerMismatch(expected: "hq", actual: "other"))
        }
        try await assertLivePullError(gate: gate, peer: "hq", expected: "manifest_peer_mismatch")
    }

    func testLivePullNewerCompleteGenerationStillRetracts_repro() async throws {
        let paths = try makePaths()
        defer { try? FileManager.default.removeItem(at: paths.runtime.deletingLastPathComponent()) }
        let (coordinator, gate, backend) = try makeCoordinatorSharedStore(
            paths, store: paths.store, peer: "mac"
        )
        _ = try await gate.performWriteCommand(name: "migrate") { try $0.migrate() }
        let kept = makeLiveArtifact(sessionId: "kept", text: "kept")
        let removed = makeLiveArtifact(sessionId: "removed", text: "removed")
        try await storeLiveSnapshot(
            backend: backend,
            sourcePeer: "hq",
            generation: 1,
            seq: 1,
            artifacts: [kept, removed]
        )
        let initialPull = try await coordinator.pullLivePeer(peer: "hq")
        XCTAssertEqual(initialPull.imported, 2)

        try await storeLiveSnapshot(
            backend: backend,
            sourcePeer: "hq",
            generation: 2,
            seq: 2,
            artifacts: [kept],
            withdrawnCount: 1
        )
        let result = try await coordinator.pullLivePeer(peer: "hq")

        XCTAssertEqual(result.retracted, 1)
        _ = try await gate.performReadCommand(name: "verifyPositiveRetract") { writer in
            try writer.read { db in
                XCTAssertNil(
                    try String.fetchOne(
                        db,
                        sql: "SELECT id FROM sessions WHERE id = ?",
                        arguments: [ImportRepo.importedLocalId(peer: "hq", sessionId: "removed")]
                    )
                )
            }
        }
    }

    func testLivePullIsolatesMissingAndHashMismatchedBundlesWithoutRetracting_repro() async throws {
        let paths = try makePaths()
        defer { try? FileManager.default.removeItem(at: paths.runtime.deletingLastPathComponent()) }
        let (coordinator, gate, backend) = try makeCoordinatorSharedStore(
            paths, store: paths.store, peer: "mac"
        )
        _ = try await gate.performWriteCommand(name: "migrate") { try $0.migrate() }

        let legacy = makeLiveArtifact(sessionId: "legacy", text: "legacy retained")
        try await storeLiveSnapshot(
            backend: backend,
            sourcePeer: "hq",
            generation: 1,
            seq: 1,
            artifacts: [legacy]
        )
        let initialResult = try await coordinator.pullLivePeer(peer: "hq")
        XCTAssertEqual(initialResult.imported, 1)

        let missing = makeLiveArtifact(sessionId: "missing", text: "missing bundle")
        let goodAfterMissing = makeLiveArtifact(sessionId: "good-1", text: "good after missing")
        try await storeLiveSnapshot(
            backend: backend,
            sourcePeer: "hq",
            generation: 2,
            seq: 2,
            artifacts: [missing, goodAfterMissing]
        )
        try await backend.delete(key: missing.entry.remoteKey)

        let missingResult = try await coordinator.pullLivePeer(peer: "hq")

        XCTAssertEqual(missingResult.imported, 1)
        XCTAssertEqual(missingResult.skipped, 1)
        XCTAssertEqual(missingResult.retracted, 0)

        let hashMismatch = makeLiveArtifact(
            sessionId: "hash-mismatch",
            text: "mismatched bundle",
            advertisedContentHash: String(repeating: "f", count: 64)
        )
        let goodAfterMismatch = makeLiveArtifact(sessionId: "good-2", text: "good after mismatch")
        try await storeLiveSnapshot(
            backend: backend,
            sourcePeer: "hq",
            generation: 3,
            seq: 3,
            artifacts: [hashMismatch, goodAfterMismatch]
        )

        let mismatchResult = try await coordinator.pullLivePeer(peer: "hq")

        XCTAssertEqual(mismatchResult.imported, 1)
        XCTAssertEqual(mismatchResult.skipped, 1)
        XCTAssertEqual(mismatchResult.retracted, 0)
        _ = try await gate.performReadCommand(name: "verifyBadBundleIsolation") { writer in
            try writer.read { db in
                for remoteId in ["legacy", "good-1", "good-2"] {
                    XCTAssertNotNil(
                        try String.fetchOne(
                            db,
                            sql: "SELECT id FROM sessions WHERE id = ?",
                            arguments: [ImportRepo.importedLocalId(peer: "hq", sessionId: remoteId)]
                        )
                    )
                }
                for remoteId in ["missing", "hash-mismatch"] {
                    XCTAssertNil(
                        try String.fetchOne(
                            db,
                            sql: "SELECT id FROM sessions WHERE id = ?",
                            arguments: [ImportRepo.importedLocalId(peer: "hq", sessionId: remoteId)]
                        )
                    )
                }
                XCTAssertEqual(
                    try String.fetchOne(
                        db,
                        sql: "SELECT value FROM metadata WHERE key = 'live_ingest.hq.last_error'"
                    ),
                    "bundle_failure"
                )
            }
        }
    }

    private func assertLivePullError(
        gate: ServiceWriterGate,
        peer: String,
        expected: String
    ) async throws {
        _ = try await gate.performReadCommand(name: "verifyLivePullError") { writer in
            try writer.read { db in
                XCTAssertEqual(
                    try String.fetchOne(
                        db,
                        sql: "SELECT value FROM metadata WHERE key = ?",
                        arguments: ["live_ingest.\(peer).last_error"]
                    ),
                    expected
                )
            }
        }
    }

    func testLivePullRejectsDispatchedManifestEntry_repro() async throws {
        let paths = try makePaths()
        defer { try? FileManager.default.removeItem(at: paths.runtime.deletingLastPathComponent()) }
        let (coordinator, gate, backend) = try makeCoordinatorSharedStore(paths, store: paths.store, peer: "mac")
        _ = try await gate.performWriteCommand(name: "migrate") { try $0.migrate() }

        func artifact(
            sessionId: String,
            agentRole: String?
        ) -> (entry: SyncManifestEntry, bundle: RemoteSessionBundle) {
            let bundle = BundleCodec.makeBundle(
                sessionId: sessionId,
                ftsContents: ["\(sessionId) searchable"],
                summary: nil,
                summaryMessageCount: nil,
                messageCount: 1,
                userMessageCount: 1,
                assistantMessageCount: 0,
                toolMessageCount: 0,
                systemMessageCount: 0,
                tier: "normal",
                agentRole: agentRole
            )
            return (
                SyncManifestEntry(
                    sessionId: sessionId,
                    source: "codex",
                    project: "demo",
                    title: sessionId,
                    startTime: "2026-08-30T00:00:00Z",
                    endTime: nil,
                    messageCount: 1,
                    userMessageCount: 1,
                    assistantMessageCount: 0,
                    systemMessageCount: 0,
                    toolMessageCount: 0,
                    summary: nil,
                    summaryMessageCount: nil,
                    sizeBytes: 1,
                    tier: "normal",
                    remoteKey: BundleCodec.contentKey(bundle),
                    contentHash: bundle.contentHash,
                    agentRole: agentRole
                ),
                bundle
            )
        }

        let visible = artifact(sessionId: "visible", agentRole: nil)
        let dispatched = artifact(sessionId: "dispatched", agentRole: "dispatched")
        try await backend.put(key: visible.entry.remoteKey, data: BundleCodec.encode(visible.bundle))
        try await backend.put(key: dispatched.entry.remoteKey, data: BundleCodec.encode(dispatched.bundle))
        let manifest = SyncManifest(
            peer: "hq",
            updatedAt: "2026-08-30T00:00:00Z",
            entries: [visible.entry, dispatched.entry]
        )
        let manifestData = try ManifestCodec.encodeLiveManifest(manifest)
        let manifestKey = LiveIngestKeys.manifest(peer: "hq", generation: 1, seq: 1)
        try await backend.put(key: manifestKey, data: manifestData)
        try await backend.put(
            key: LiveIngestKeys.head(peer: "hq"),
            data: ManifestCodec.encodeLiveHead(
                LiveIngestHead(
                    peer: "hq",
                    generation: 1,
                    seq: 1,
                    complete: true,
                    entryCount: 2,
                    manifestKey: manifestKey,
                    contentHash: ManifestCodec.liveManifestContentHash(manifestData),
                    withdrawnCount: 0
                )
            )
        )

        let result = try await coordinator.pullLivePeer(peer: "hq")

        XCTAssertEqual(result.imported, 1)
        XCTAssertEqual(result.skipped, 1)
        _ = try await gate.performReadCommand(name: "verifyDispatchedFiltered") { writer in
            try writer.read { db in
                XCTAssertNotNil(
                    try String.fetchOne(
                        db,
                        sql: "SELECT id FROM sessions WHERE id = ?",
                        arguments: [ImportRepo.importedLocalId(peer: "hq", sessionId: "visible")]
                    )
                )
                XCTAssertNil(
                    try String.fetchOne(
                        db,
                        sql: "SELECT id FROM sessions WHERE id = ?",
                        arguments: [ImportRepo.importedLocalId(peer: "hq", sessionId: "dispatched")]
                    )
                )
            }
        }
    }

    func testLiveListingDoesNotUseOffloadCatalog_repro() async throws {
        let store = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("engram-livecat-\(UUID().uuidString.prefix(8))", isDirectory: true)
            .appendingPathComponent("store", isDirectory: true)
        let pathsA = try makePaths(); let pathsB = try makePaths()
        defer {
            try? FileManager.default.removeItem(at: pathsA.runtime.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: pathsB.runtime.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: store.deletingLastPathComponent())
        }
        let (coordHQ, gateHQ, inner) = try makeCoordinatorSharedStore(pathsA, store: store, peer: "hq")
        _ = try await gateHQ.performWriteCommand(name: "migrate") { try $0.migrate() }
        try await seedLocal(gateHQ, id: "hq1", fts: ["catalog forbidden keyword"])
        _ = try await coordHQ.publishLivePeer(batch: 50, completeWalk: true)

        let forbidden = CatalogForbiddenBackend(inner: inner)
        let gateMac = try ServiceWriterGate(
            databasePath: pathsB.database.path, runtimeDirectory: pathsB.runtime
        )
        _ = try await gateMac.performWriteCommand(name: "migrate") { try $0.migrate() }
        let coordMac = RemoteSyncCoordinator(
            gate: gateMac,
            backend: forbidden,
            config: RemoteSyncConfig(
                enabled: true, storeRoot: store, policy: OffloadPolicy(coldAgeDays: 90),
                offloadBatch: 20, rehydrateBatch: 20, vacuumFreelistThreshold: 1_000_000
            ),
            peer: "mac"
        )
        let pulled = try await coordMac.pullLivePeer(peer: "hq")
        XCTAssertEqual(pulled.imported, 1)
        let catalogCalled = await forbidden.didCallCatalog()
        XCTAssertFalse(catalogCalled, "live pull must GET live.hq.head, not catalog()")
    }

    func testLivePullDoesNotRetractFromIncompleteManifest_repro() async throws {
        let store = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("engram-liveinc-\(UUID().uuidString.prefix(8))", isDirectory: true)
            .appendingPathComponent("store", isDirectory: true)
        let pathsA = try makePaths(); let pathsB = try makePaths()
        defer {
            try? FileManager.default.removeItem(at: pathsA.runtime.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: pathsB.runtime.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: store.deletingLastPathComponent())
        }
        let (coordHQ, gateHQ, _) = try makeCoordinatorSharedStore(pathsA, store: store, peer: "hq")
        let (coordMac, gateMac, _) = try makeCoordinatorSharedStore(pathsB, store: store, peer: "mac")
        _ = try await gateHQ.performWriteCommand(name: "migrate") { try $0.migrate() }
        _ = try await gateMac.performWriteCommand(name: "migrate") { try $0.migrate() }
        try await seedLocal(gateHQ, id: "a1", fts: ["first page"])
        try await seedLocal(gateHQ, id: "a2", fts: ["second page"])
        let (stale, staleBundle) = (
            SyncManifestEntry(
                sessionId: "stale", source: "codex", project: "demo", title: "Stale",
                startTime: "2024-01-01T00:00:00Z", endTime: nil, messageCount: 1,
                userMessageCount: 1, assistantMessageCount: 0, systemMessageCount: 0,
                toolMessageCount: 0, summary: "stale", summaryMessageCount: 1, sizeBytes: 1,
                tier: "normal", remoteKey: "stale.bundle", contentHash: "stale"
            ),
            BundleCodec.makeBundle(
                sessionId: "stale", ftsContents: ["stale term"], summary: "stale",
                summaryMessageCount: 1, messageCount: 1, userMessageCount: 1,
                assistantMessageCount: 0, toolMessageCount: 0, systemMessageCount: 0
            )
        )
        _ = try await gateMac.performWriteCommand(name: "seedStale") { writer in
            try writer.write { db in
                try ImportRepo.commitImported(db, entry: stale, peer: "hq", bundle: staleBundle)
            }
        }

        let first = try await coordHQ.publishLivePeer(batch: 1, completeWalk: false)
        XCTAssertFalse(first.complete)
        XCTAssertEqual(first.publishedEntries, 1, "incomplete blob is ledger so far, not an empty prefix")
        _ = try await coordMac.pullLivePeer(peer: "hq")
        let staleId = ImportRepo.importedLocalId(peer: "hq", sessionId: "stale")
        _ = try await gateMac.performWriteCommand(name: "staleStays") { writer in
            try writer.read { db in
                XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sessions WHERE id = ?", arguments: [staleId]), 1)
            }
        }

        let second = try await coordHQ.publishLivePeer(batch: 1, completeWalk: false)
        XCTAssertTrue(second.complete)
        XCTAssertEqual(second.publishedEntries, 2, "assembly is the full ledger join, not the last batch")
    }

    func testLivePullSkipsOccupancyAtCoordinator_repro() async throws {
        let store = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("engram-liveocc-\(UUID().uuidString.prefix(8))", isDirectory: true)
            .appendingPathComponent("store", isDirectory: true)
        let pathsA = try makePaths(); let pathsB = try makePaths()
        defer {
            try? FileManager.default.removeItem(at: pathsA.runtime.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: pathsB.runtime.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: store.deletingLastPathComponent())
        }
        let (coordHQ, gateHQ, _) = try makeCoordinatorSharedStore(pathsA, store: store, peer: "hq")
        let (coordMac, gateMac, _) = try makeCoordinatorSharedStore(pathsB, store: store, peer: "mac")
        _ = try await gateHQ.performWriteCommand(name: "migrate") { try $0.migrate() }
        _ = try await gateMac.performWriteCommand(name: "migrate") { try $0.migrate() }
        try await seedLocal(gateHQ, id: "shared", fts: ["hq copy"])
        try await seedLocal(gateMac, id: "shared", fts: ["mac original"])
        _ = try await gateMac.performWriteCommand(name: "hideLocal") { writer in
            try writer.write { db in
                try db.execute(sql: "UPDATE sessions SET tier = 'skip' WHERE id = 'shared'")
            }
        }
        _ = try await coordHQ.publishLivePeer(batch: 50, completeWalk: true)
        let pulled = try await coordMac.pullLivePeer(peer: "hq")
        XCTAssertEqual(pulled.occupancySkipped, 1)
        XCTAssertEqual(pulled.imported, 0)
        _ = try await gateMac.performWriteCommand(name: "noDup") { writer in
            try writer.read { db in
                XCTAssertNil(
                    try String.fetchOne(
                        db, sql: "SELECT id FROM sessions WHERE id = ?",
                        arguments: [ImportRepo.importedLocalId(peer: "hq", sessionId: "shared")]
                    )
                )
            }
        }
    }

    func testLivePullShrinkGuardFailsClosedAndRecovers_repro() async throws {
        let store = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("engram-liveshrink-\(UUID().uuidString.prefix(8))", isDirectory: true)
            .appendingPathComponent("store", isDirectory: true)
        let pathsA = try makePaths(); let pathsB = try makePaths()
        defer {
            try? FileManager.default.removeItem(at: pathsA.runtime.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: pathsB.runtime.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: store.deletingLastPathComponent())
        }
        let (coordHQ, gateHQ, _) = try makeCoordinatorSharedStore(pathsA, store: store, peer: "hq")
        let (coordMac, gateMac, _) = try makeCoordinatorSharedStore(pathsB, store: store, peer: "mac")
        _ = try await gateHQ.performWriteCommand(name: "migrate") { try $0.migrate() }
        _ = try await gateMac.performWriteCommand(name: "migrate") { try $0.migrate() }
        for i in 0..<51 {
            try await seedLocal(gateHQ, id: String(format: "h%02d", i), fts: ["shrink \(i)"])
        }
        _ = try await coordHQ.publishLivePeer(batch: 50, completeWalk: true)
        let firstPull = try await coordMac.pullLivePeer(peer: "hq")
        XCTAssertEqual(firstPull.imported, 51)

        _ = try await gateHQ.performWriteCommand(name: "skipAll") { writer in
            try writer.write { db in
                try db.execute(sql: "UPDATE sessions SET tier = 'skip'")
            }
        }
        try await seedLocal(gateHQ, id: "new-after", fts: ["brand new after shrink"])
        _ = try await coordHQ.publishLivePeer(batch: 50, completeWalk: true)

        do {
            _ = try await coordMac.pullLivePeer(peer: "hq")
            XCTFail("over-cap retract must fail closed on the first complete shrink")
        } catch {
            XCTAssertEqual(error as? RemoteSyncError, .liveShrinkGuardLatched("hq"))
        }
        _ = try await gateMac.performWriteCommand(name: "stillThere") { writer in
            try writer.read { db in
                XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sessions WHERE origin = 'hq'"), 51)
                XCTAssertEqual(
                    try String.fetchOne(db, sql: "SELECT value FROM metadata WHERE key = 'live_ingest.hq.shrink_guard_latched'"),
                    "1"
                )
            }
        }

        let latched = try await coordMac.pullLivePeer(peer: "hq")
        XCTAssertEqual(latched.imported, 1, "while latched, new entries still import")
        XCTAssertEqual(latched.retracted, 0)
        XCTAssertTrue(latched.shrinkGuardLatched)
        _ = try await gateMac.performWriteCommand(name: "importedNew") { writer in
            try writer.read { db in
                XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sessions WHERE origin = 'hq'"), 52)
            }
        }

        _ = try await gateHQ.performWriteCommand(name: "restore") { writer in
            try writer.write { db in
                try db.execute(sql: "UPDATE sessions SET tier = 'normal' WHERE id != 'new-after'")
            }
        }
        _ = try await coordHQ.publishLivePeer(batch: 50, completeWalk: true)
        try await coordMac.resetLiveIngestShrinkGuard(peer: "hq")
        let recovered = try await coordMac.pullLivePeer(peer: "hq")
        XCTAssertFalse(recovered.shrinkGuardLatched)
        XCTAssertEqual(recovered.retracted, 0)
        _ = try await gateMac.performWriteCommand(name: "unlatched") { writer in
            try writer.read { db in
                XCTAssertNil(
                    try String.fetchOne(
                        db, sql: "SELECT value FROM metadata WHERE key = 'live_ingest.hq.shrink_guard_latched'"
                    )
                )
                XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sessions WHERE origin = 'hq'"), 52)
            }
        }
    }

    func testLiveGenerationBlobRetentionKeepsCurrentAndPrevious_repro() async throws {
        let store = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("engram-livegc-\(UUID().uuidString.prefix(8))", isDirectory: true)
            .appendingPathComponent("store", isDirectory: true)
        let paths = try makePaths()
        defer {
            try? FileManager.default.removeItem(at: paths.runtime.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: store.deletingLastPathComponent())
        }
        let (coord, gate, backend) = try makeCoordinatorSharedStore(paths, store: store, peer: "hq")
        _ = try await gate.performWriteCommand(name: "migrate") { try $0.migrate() }
        try await seedLocal(gate, id: "hq1", fts: ["retention"])
        var keys: [String] = []
        for revision in 0..<3 {
            if revision > 0 {
                _ = try await gate.performWriteCommand(name: "changePublishedCorpus") { writer in
                    try writer.write { db in
                        try db.execute(sql: "DELETE FROM sessions_fts WHERE session_id = 'hq1'")
                        try db.execute(
                            sql: "INSERT INTO sessions_fts(session_id, content) VALUES ('hq1', ?)",
                            arguments: ["retention revision \(revision)"]
                        )
                        try db.execute(
                            sql: """
                            UPDATE sessions
                            SET indexed_at = datetime('now', ?),
                                sync_version = sync_version + 1
                            WHERE id = 'hq1'
                            """,
                            arguments: ["+\(revision) seconds"]
                        )
                    }
                }
            }
            let result = try await coord.publishLivePeer(batch: 50, completeWalk: true)
            XCTAssertTrue(result.complete)
            keys.append(LiveIngestKeys.manifest(peer: "hq", generation: result.generation, seq: result.seq))
        }
        XCTAssertEqual(keys.count, 3)
        let firstGone = try await backend.head(key: keys[0])
        let previousKept = try await backend.head(key: keys[1])
        let currentKept = try await backend.head(key: keys[2])
        let headKept = try await backend.head(key: LiveIngestKeys.head(peer: "hq"))
        XCTAssertFalse(firstGone, "older than previous complete is deleted")
        XCTAssertTrue(previousKept)
        XCTAssertTrue(currentKept)
        XCTAssertTrue(headKept)
    }

    func testIncompleteManifestSurvivesOneHeadAdvanceAndDeletesAfterTwo_repro() async throws {
        let paths = try makePaths()
        defer { try? FileManager.default.removeItem(at: paths.runtime.deletingLastPathComponent()) }
        let (coordinator, gate, backend) = try makeCoordinatorSharedStore(
            paths, store: paths.store, peer: "hq"
        )
        _ = try await gate.performWriteCommand(name: "migrate") { try $0.migrate() }
        for index in 0..<4 {
            try await seedLocal(gate, id: "page-\(index)", fts: ["page \(index)"])
        }

        let first = try await coordinator.publishLivePeer(batch: 1, completeWalk: false)
        XCTAssertFalse(first.complete)
        let firstKey = LiveIngestKeys.manifest(
            peer: "hq", generation: first.generation, seq: first.seq
        )

        let second = try await coordinator.publishLivePeer(batch: 1, completeWalk: false)
        XCTAssertFalse(second.complete)
        let secondKey = LiveIngestKeys.manifest(
            peer: "hq", generation: second.generation, seq: second.seq
        )
        let firstKeptAfterOneAdvance = try await backend.head(key: firstKey)
        XCTAssertTrue(
            firstKeptAfterOneAdvance,
            "a reader of the previous head still needs its incomplete manifest"
        )

        let third = try await coordinator.publishLivePeer(batch: 1, completeWalk: false)
        XCTAssertFalse(third.complete)
        let thirdKey = LiveIngestKeys.manifest(
            peer: "hq", generation: third.generation, seq: third.seq
        )
        let firstGoneAfterTwoAdvances = try await backend.head(key: firstKey)
        let secondKept = try await backend.head(key: secondKey)
        let thirdKept = try await backend.head(key: thirdKey)
        XCTAssertFalse(
            firstGoneAfterTwoAdvances,
            "an incomplete manifest may be deleted after two later head publications"
        )
        XCTAssertTrue(secondKept)
        XCTAssertTrue(thirdKept)
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

private final class RunnerTwoPhaseFTSAdapter: SessionAdapter {
    let source = SourceName.codex
    private let contents: [String]

    init(contents: [String]) {
        self.contents = contents
    }

    func detect() async -> Bool { true }
    func listSessionLocators() async throws -> [String] { [] }
    func isAccessible(locator: String) async -> Bool { true }

    func parseSessionInfo(locator: String) async throws -> AdapterParseResult<NormalizedSessionInfo> {
        .failure(.fileMissing)
    }

    func streamMessages(
        locator: String,
        options: StreamMessagesOptions
    ) async throws -> AsyncThrowingStream<NormalizedMessage, Error> {
        let messages = contents.map { NormalizedMessage(role: .user, content: $0) }
        return AsyncThrowingStream<NormalizedMessage, Error> { continuation in
            for message in messages {
                continuation.yield(message)
            }
            continuation.finish()
        }
    }
}

/// Test backend delegating to a real `LocalDirectoryBackend` but, once `arm()`ed,
/// failing `get` for keys containing `failKeySubstring` with a transient (non
/// "absent") error — to exercise pushProject's fail-closed manifest-merge path.
private actor CatalogForbiddenBackend: RemoteStorageBackend {
    private let inner: LocalDirectoryBackend
    private var catalogCalled = false

    init(inner: LocalDirectoryBackend) {
        self.inner = inner
    }

    func didCallCatalog() -> Bool { catalogCalled }

    func head(key: String) async throws -> Bool { try await inner.head(key: key) }
    func put(key: String, data: Data) async throws { try await inner.put(key: key, data: data) }
    func get(key: String) async throws -> Data { try await inner.get(key: key) }
    func delete(key: String) async throws { try await inner.delete(key: key) }
    func catalog() async throws -> Data {
        catalogCalled = true
        throw RemoteSyncError.catalogTooLarge
    }
}

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

private struct ExistingWrongBundleBackend: RemoteStorageBackend {
    let data: Data

    func head(key: String) async throws -> Bool { true }
    func put(key: String, data: Data) async throws {}
    func get(key: String) async throws -> Data { data }
    func delete(key: String) async throws {}
    func catalog() async throws -> Data { Data() }
}

private actor RecordingRemoteStorageBackend: RemoteStorageBackend {
    struct Observations: Sendable, Equatable {
        let headKeys: [String]
        let putKeys: [String]
    }

    private let inner: LocalDirectoryBackend
    private var headKeys: [String] = []
    private var putKeys: [String] = []

    init(inner: LocalDirectoryBackend) {
        self.inner = inner
    }

    func resetObservations() {
        headKeys = []
        putKeys = []
    }

    func observations() -> Observations {
        Observations(headKeys: headKeys, putKeys: putKeys)
    }

    func head(key: String) async throws -> Bool {
        headKeys.append(key)
        return try await inner.head(key: key)
    }

    func put(key: String, data: Data) async throws {
        putKeys.append(key)
        try await inner.put(key: key, data: data)
    }

    func get(key: String) async throws -> Data { try await inner.get(key: key) }
    func delete(key: String) async throws { try await inner.delete(key: key) }
    func catalog() async throws -> Data { try await inner.catalog() }
}

private actor FailingHeadPutRemoteStorageBackend: RemoteStorageBackend {
    private let inner: LocalDirectoryBackend
    private let headKey: String
    private var armed = false

    init(inner: LocalDirectoryBackend, headKey: String) {
        self.inner = inner
        self.headKey = headKey
    }

    func arm() { armed = true }

    func head(key: String) async throws -> Bool { try await inner.head(key: key) }
    func put(key: String, data: Data) async throws {
        if armed, key == headKey {
            throw EngramRemoteBackendError.unexpectedStatus(503)
        }
        try await inner.put(key: key, data: data)
    }
    func get(key: String) async throws -> Data { try await inner.get(key: key) }
    func delete(key: String) async throws { try await inner.delete(key: key) }
    func catalog() async throws -> Data { try await inner.catalog() }
}

private actor BlockingLiveHeadPutRemoteStorageBackend: RemoteStorageBackend {
    private let inner: LocalDirectoryBackend
    private let headKey: String
    private var didBlock = false
    private var isBlocked = false
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []
    private var blockObservers: [CheckedContinuation<Void, Never>] = []

    init(inner: LocalDirectoryBackend, headKey: String) {
        self.inner = inner
        self.headKey = headKey
    }

    func waitUntilHeadPutIsBlocked() async {
        guard !isBlocked else { return }
        await withCheckedContinuation { continuation in
            blockObservers.append(continuation)
        }
    }

    func releaseHeadPut() {
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    func head(key: String) async throws -> Bool { try await inner.head(key: key) }
    func put(key: String, data: Data) async throws {
        if !didBlock, key == headKey {
            didBlock = true
            isBlocked = true
            let observers = blockObservers
            blockObservers.removeAll()
            observers.forEach { $0.resume() }
            await withCheckedContinuation { continuation in
                releaseWaiters.append(continuation)
            }
            isBlocked = false
        }
        try await inner.put(key: key, data: data)
    }
    func get(key: String) async throws -> Data { try await inner.get(key: key) }
    func delete(key: String) async throws { try await inner.delete(key: key) }
    func catalog() async throws -> Data { try await inner.catalog() }
}

private actor BlockingBundleHeadRemoteStorageBackend: RemoteStorageBackend {
    private let inner: LocalDirectoryBackend
    private var didBlock = false
    private var isBlocked = false
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []
    private var blockObservers: [CheckedContinuation<Void, Never>] = []

    init(inner: LocalDirectoryBackend) {
        self.inner = inner
    }

    func waitUntilBundleHeadIsBlocked() async {
        guard !isBlocked else { return }
        await withCheckedContinuation { continuation in
            blockObservers.append(continuation)
        }
    }

    func bundleHeadIsBlocked() -> Bool { isBlocked }

    func releaseBundleHead() {
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    func head(key: String) async throws -> Bool {
        if !didBlock, key.hasSuffix(".bundle") {
            didBlock = true
            isBlocked = true
            let observers = blockObservers
            blockObservers.removeAll()
            observers.forEach { $0.resume() }
            await withCheckedContinuation { continuation in
                releaseWaiters.append(continuation)
            }
        }
        return try await inner.head(key: key)
    }

    func put(key: String, data: Data) async throws { try await inner.put(key: key, data: data) }
    func get(key: String) async throws -> Data { try await inner.get(key: key) }
    func delete(key: String) async throws { try await inner.delete(key: key) }
    func catalog() async throws -> Data { try await inner.catalog() }
}

private actor BeforeGetRemoteStorageBackend: RemoteStorageBackend {
    private let inner: LocalDirectoryBackend
    private let triggerKey: String
    private let beforeGet: @Sendable () async throws -> Void
    private var didTrigger = false

    init(
        inner: LocalDirectoryBackend,
        triggerKey: String,
        beforeGet: @escaping @Sendable () async throws -> Void
    ) {
        self.inner = inner
        self.triggerKey = triggerKey
        self.beforeGet = beforeGet
    }

    func head(key: String) async throws -> Bool { try await inner.head(key: key) }
    func put(key: String, data: Data) async throws { try await inner.put(key: key, data: data) }
    func get(key: String) async throws -> Data {
        if key == triggerKey, !didTrigger {
            didTrigger = true
            try await beforeGet()
        }
        return try await inner.get(key: key)
    }
    func delete(key: String) async throws { try await inner.delete(key: key) }
    func catalog() async throws -> Data { try await inner.catalog() }
}
