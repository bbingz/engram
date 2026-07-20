import EngramCoreRead
import EngramCoreWrite
import GRDB
import XCTest

final class RemoteOffloadTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("engram-offload-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        try super.tearDownWithError()
    }

    // MARK: - BundleCodec

    func testBundleCodecRoundTripsAndVerifies() throws {
        let bundle = BundleCodec.makeBundle(
            sessionId: "s1",
            ftsContents: ["hello world", "second message", "the summary"],
            summary: "the summary",
            summaryMessageCount: 2,
            messageCount: 2,
            userMessageCount: 1,
            assistantMessageCount: 1,
            toolMessageCount: 0,
            systemMessageCount: 0
        )
        let data = try BundleCodec.encode(bundle)
        let decoded = try BundleCodec.decode(data, expectedSessionId: "s1")
        XCTAssertEqual(decoded, bundle)
        XCTAssertEqual(BundleCodec.recomputeHash(bundle), bundle.contentHash)
    }

    func testBundleCodecDetectsTamper() throws {
        let bundle = BundleCodec.makeBundle(
            sessionId: "s1", ftsContents: ["a"], summary: nil, summaryMessageCount: nil,
            messageCount: 1, userMessageCount: 1, assistantMessageCount: 0,
            toolMessageCount: 0, systemMessageCount: 0
        )
        // Forge a bundle whose stored hash no longer matches its contents.
        let forged = RemoteSessionBundle(
            sessionId: "s1", ftsContents: ["a", "INJECTED"], summary: nil, summaryMessageCount: nil,
            messageCount: 1, userMessageCount: 1, assistantMessageCount: 0,
            toolMessageCount: 0, systemMessageCount: 0, contentHash: bundle.contentHash
        )
        XCTAssertThrowsError(try BundleCodec.decode(try JSONEncoder().encode(forged))) { error in
            guard case RemoteSyncError.contentHashMismatch = error else {
                return XCTFail("expected contentHashMismatch, got \(error)")
            }
        }
    }

    func testLocalDirectoryBackendRejectsTraversalKeys() async throws {
        let store = tempDir.appendingPathComponent("store", isDirectory: true)
        let secret = tempDir.appendingPathComponent("secret.bundle")
        try Data("secret".utf8).write(to: secret)
        let backend = try LocalDirectoryBackend(root: store)

        do {
            _ = try await backend.get(key: "../secret.bundle")
            XCTFail("LocalDirectoryBackend must not read keys outside the configured root")
        } catch {
            // expected: invalid keys should be rejected before filesystem access.
        }
    }

    // MARK: - OffloadPolicy

    func testPolicyEligibility() {
        let policy = OffloadPolicy(coldAgeDays: 90)
        let now = Date(timeIntervalSince1970: 1_750_000_000) // fixed reference
        func row(state: String? = "local", hidden: String? = nil, tier: String? = "normal",
                 role: String? = nil, last: String?) -> OffloadPolicy.SessionRow {
            OffloadPolicy.SessionRow(id: "x", offloadState: state, hiddenAt: hidden, tier: tier,
                                     agentRole: role, lastActivity: last, sizeBytes: 1000)
        }
        let recent = ISO8601DateFormatter().string(from: now.addingTimeInterval(-86_400)) // 1 day ago
        let old = ISO8601DateFormatter().string(from: now.addingTimeInterval(-200 * 86_400)) // 200 days ago

        XCTAssertTrue(policy.isEligible(row(hidden: "2026-01-01T00:00:00Z", last: recent), now: now),
                      "hidden/archived is always eligible")
        XCTAssertTrue(policy.isEligible(row(last: old), now: now), "visible-but-cold is eligible")
        XCTAssertFalse(policy.isEligible(row(last: recent), now: now), "visible & recent is not")
        XCTAssertFalse(policy.isEligible(row(state: "offloaded", last: old), now: now), "already offloaded")
        XCTAssertFalse(policy.isEligible(row(tier: "skip", last: old), now: now), "skip never offloaded")
        XCTAssertFalse(policy.isEligible(row(role: "subagent", last: old), now: now), "subagent never offloaded")
    }

    // MARK: - VACUUM reclaim (BLOCKER #2)

    func testVacuumReturnsFreelistPagesToFile() throws {
        let writer = try EngramDatabaseWriter(path: tempDir.appendingPathComponent("vac.sqlite").path)
        try writer.migrate()
        // A plain b-tree fills and frees whole pages deterministically (FTS5
        // deletes are logical tombstones, so they would not move pages to the
        // freelist until a merge). This models the disk a bulk purge leaves behind.
        try writer.write { db in
            try db.execute(sql: "CREATE TABLE bulk_pad(id INTEGER PRIMARY KEY, blob TEXT)")
            for _ in 0..<5000 {
                try db.execute(sql: "INSERT INTO bulk_pad(blob) VALUES (?)",
                               arguments: [String(repeating: "x", count: 400)])
            }
        }
        try writer.write { db in
            try db.execute(sql: "DELETE FROM bulk_pad")
        }
        let freeBefore = try writer.freelistPageCount()
        XCTAssertGreaterThan(freeBefore, 0, "bulk delete should leave reusable free pages (not yet returned to OS)")
        try writer.vacuum()
        let freeAfter = try writer.freelistPageCount()
        XCTAssertEqual(freeAfter, 0, "VACUUM returns the free pages to the OS")
    }

    // MARK: - Full offload → re-index guard → rehydrate cycle

    func testOffloadRehydrateCycleWithReindexGuard() async throws {
        let writer = try EngramDatabaseWriter(path: tempDir.appendingPathComponent("idx.sqlite").path)
        try writer.migrate()

        let fullContents = ["first user message", "first assistant reply", "second user message", "session summary"]
        try writer.write { db in
            try db.execute(sql: """
                INSERT INTO sessions(id, source, start_time, end_time, file_path, project,
                                     summary, summary_message_count, message_count,
                                     user_message_count, assistant_message_count,
                                     generated_title, size_bytes, hidden_at)
                VALUES ('sess-1', 'codex', '2024-01-01T00:00:00Z', '2024-01-01T01:00:00Z',
                        '/tmp/sess-1.jsonl', 'demo-project', 'session summary', 3, 3, 2, 1,
                        'Demo session title', 4096, '2024-02-01T00:00:00Z');
            """)
            for line in fullContents {
                try db.execute(sql: "INSERT INTO sessions_fts(session_id, content) VALUES ('sess-1', ?)",
                               arguments: [line])
            }
        }

        let backend = try LocalDirectoryBackend(root: tempDir.appendingPathComponent("store"))
        let runner = OffloadRunner(writer: writer, backend: backend, policy: OffloadPolicy(coldAgeDays: 90), peer: "test-peer")

        // 1. Offload (hidden session → eligible). Full FTS rows collapse to one shadow row.
        let offloadOutcome = try await runner.runOffloadOnce(now: Date())
        XCTAssertEqual(offloadOutcome, OffloadRunner.SyncOutcome(succeeded: 1, failed: 0))

        try writer.read { db in
            XCTAssertEqual(try OffloadRepo.offloadState(db, sessionId: "sess-1"), "offloaded")
            let ftsCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sessions_fts WHERE session_id = 'sess-1'")
            XCTAssertEqual(ftsCount, 1, "offloaded session keeps only the keyword shadow")
            let ledger = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sync_ledger WHERE session_id = 'sess-1' AND direction = 'out'")
            XCTAssertEqual(ledger, 1)
        }
        // Shadow is still keyword-discoverable.
        try writer.read { db in
            let hit = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sessions_fts WHERE content MATCH 'demo'")
            XCTAssertEqual(hit, 1, "offloaded session remains findable via the shadow")
        }

        // 2. Re-index guard: a routine FTS job MUST NOT re-materialize the full transcript.
        try writer.write { db in
            try db.execute(sql: """
                INSERT INTO session_index_jobs(id, session_id, job_kind, target_sync_version, status)
                VALUES ('job-1', 'sess-1', 'fts', 0, 'pending');
            """)
        }
        _ = try await IndexJobRunner(writer: writer).runRecoverableJobsOnce()
        try writer.read { db in
            let ftsCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sessions_fts WHERE session_id = 'sess-1'")
            XCTAssertEqual(ftsCount, 1, "re-index must keep only the shadow, not restore full content")
        }

        // 3. Rehydrate: full FTS content + summary restored, state back to local.
        try writer.write { db in
            _ = try OffloadRepo.enqueueRehydrate(db, sessionId: "sess-1")
        }
        let rehydrateOutcome = try await runner.runRehydrateOnce()
        XCTAssertEqual(rehydrateOutcome, OffloadRunner.SyncOutcome(succeeded: 1, failed: 0))

        try writer.read { db in
            XCTAssertEqual(try OffloadRepo.offloadState(db, sessionId: "sess-1"), "local")
            let restored = Set(try String.fetchAll(db, sql: "SELECT content FROM sessions_fts WHERE session_id = 'sess-1'"))
            XCTAssertEqual(restored, Set(fullContents), "rehydrate restores the full FTS content set")
            let ledgerIn = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sync_ledger WHERE session_id = 'sess-1' AND direction = 'in'")
            XCTAssertEqual(ledgerIn, 1)
        }

        // 4. Offload the unchanged session again. The content-addressed object is
        // already present, so the GET+decode+hash idempotent path must still commit.
        let idempotentOffload = try await runner.runOffloadOnce(now: Date())
        XCTAssertEqual(idempotentOffload, OffloadRunner.SyncOutcome(succeeded: 1, failed: 0))
        try writer.read { db in
            XCTAssertEqual(try OffloadRepo.offloadState(db, sessionId: "sess-1"), "offloaded")
            XCTAssertEqual(
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sessions_fts WHERE session_id = 'sess-1'"),
                1,
                "a verified matching remote object may collapse FTS to the shadow"
            )
        }
    }

    func testOffloadRunnerPreservesLocalFtsWhenExistingRemoteBundleCannotBeFetched_repro() async throws {
        let writer = try EngramDatabaseWriter(path: tempDir.appendingPathComponent("head-get-failure.sqlite").path)
        try writer.migrate()
        let fullContents = ["first original row", "second original row", "third original row"]
        try writer.write { db in
            try db.execute(sql: """
                INSERT INTO sessions(id, source, start_time, file_path, size_bytes, hidden_at)
                VALUES ('s', 'codex', '2024-01-01T00:00:00Z', '/tmp/s.jsonl', 4096, '2024-02-01T00:00:00Z')
            """)
            for line in fullContents {
                try db.execute(
                    sql: "INSERT INTO sessions_fts(session_id, content) VALUES ('s', ?)",
                    arguments: [line]
                )
            }
        }

        let runner = OffloadRunner(
            writer: writer,
            backend: ExistingButUnretrievableBackend(),
            policy: OffloadPolicy(coldAgeDays: 90)
        )

        let outcome = try await runner.runOffloadOnce(now: Date())

        XCTAssertEqual(outcome, OffloadRunner.SyncOutcome(succeeded: 0, failed: 1))
        try writer.read { db in
            XCTAssertEqual(try OffloadRepo.offloadState(db, sessionId: "s"), "local")
            XCTAssertEqual(
                try String.fetchAll(
                    db,
                    sql: "SELECT content FROM sessions_fts WHERE session_id = 's' ORDER BY rowid"
                ),
                fullContents,
                "a failed durability proof must preserve every original FTS row"
            )
            XCTAssertEqual(
                try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM sync_ledger WHERE session_id = 's' AND direction = 'out'"
                ),
                0,
                "commitOffloaded must not be reached"
            )
        }
    }

    // MARK: - Review fixes

    func testOffloadRunnerRethrowsCancellationWithoutChargingFailure() async throws {
        let writer = try EngramDatabaseWriter(path: tempDir.appendingPathComponent("offload-cancel.sqlite").path)
        try writer.migrate()
        try writer.write { db in
            try db.execute(sql: """
                INSERT INTO sessions(id, source, start_time, file_path, size_bytes, hidden_at)
                VALUES ('s', 'codex', '2024-01-01T00:00:00Z', '/tmp/s.jsonl', 4096, '2024-02-01T00:00:00Z')
            """)
            try db.execute(sql: "INSERT INTO sessions_fts(session_id, content) VALUES ('s', 'cancel me')")
        }

        let runner = OffloadRunner(
            writer: writer,
            backend: CancellingRemoteStorageBackend(cancelOn: .put),
            policy: OffloadPolicy(coldAgeDays: 90)
        )

        do {
            _ = try await runner.runOffloadOnce(now: Date())
            XCTFail("expected CancellationError")
        } catch is CancellationError {
            // expected
        }

        try writer.read { db in
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT status FROM offload_queue WHERE session_id = 's'"), "inflight")
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT attempts FROM offload_queue WHERE session_id = 's'"), 0)
        }
    }

    func testRehydrateRunnerRethrowsCancellationWithoutChargingFailure() async throws {
        let writer = try EngramDatabaseWriter(path: tempDir.appendingPathComponent("rehydrate-cancel.sqlite").path)
        try writer.migrate()
        try writer.write { db in
            try db.execute(sql: """
                INSERT INTO sessions(id, source, start_time, file_path, offload_state)
                VALUES ('s', 'codex', '2024-01-01T00:00:00Z', '/tmp/s.jsonl', 'offloaded')
            """)
            try db.execute(sql: """
                INSERT INTO sync_ledger(session_id, remote_key, direction, content_hash)
                VALUES ('s', 'remote-key', 'out', 'hash')
            """)
            _ = try OffloadRepo.enqueueRehydrate(db, sessionId: "s")
        }

        let runner = OffloadRunner(
            writer: writer,
            backend: CancellingRemoteStorageBackend(cancelOn: .get),
            policy: OffloadPolicy(coldAgeDays: 90)
        )

        do {
            _ = try await runner.runRehydrateOnce()
            XCTFail("expected CancellationError")
        } catch is CancellationError {
            // expected
        }

        try writer.read { db in
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT status FROM rehydrate_queue WHERE session_id = 's'"), "inflight")
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT attempts FROM rehydrate_queue WHERE session_id = 's'"), 0)
        }
    }

    func testRehydrateCommitAbortsWhenSyncVersionChanged() async throws {
        let writer = try EngramDatabaseWriter(path: tempDir.appendingPathComponent("rehydrate-stale.sqlite").path)
        try writer.migrate()
        let bundle = BundleCodec.makeBundle(
            sessionId: "s",
            ftsContents: ["full one", "full two"],
            summary: "full summary",
            summaryMessageCount: 2,
            messageCount: 2,
            userMessageCount: 1,
            assistantMessageCount: 1,
            toolMessageCount: 0,
            systemMessageCount: 0
        )
        try writer.write { db in
            try db.execute(sql: """
                INSERT INTO sessions(id, source, start_time, file_path, offload_state, sync_version, summary, summary_message_count)
                VALUES ('s', 'codex', '2024-01-01T00:00:00Z', '/tmp/s.jsonl', 'offloaded', 1, 'shadow summary', 1)
            """)
            try db.execute(sql: "INSERT INTO sessions_fts(session_id, content) VALUES ('s', 'shadow')")
            try db.execute(
                sql: """
                INSERT INTO sync_ledger(session_id, remote_key, direction, content_hash)
                VALUES ('s', 'remote-key', 'out', ?)
                """,
                arguments: [bundle.contentHash]
            )
            _ = try OffloadRepo.enqueueRehydrate(db, sessionId: "s")
        }

        let runner = OffloadRunner(
            writer: writer,
            backend: ConcurrentRehydrateMutationBackend(writer: writer, bundle: bundle),
            policy: OffloadPolicy(coldAgeDays: 90)
        )

        let outcome = try await runner.runRehydrateOnce()

        XCTAssertEqual(outcome, OffloadRunner.SyncOutcome(succeeded: 0, failed: 0))
        try writer.read { db in
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT offload_state FROM sessions WHERE id = 's'"), "offloaded")
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT sync_version FROM sessions WHERE id = 's'"), 2)
            XCTAssertEqual(
                try String.fetchAll(db, sql: "SELECT content FROM sessions_fts WHERE session_id = 's'"),
                ["shadow"]
            )
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT status FROM rehydrate_queue WHERE session_id = 's'"), "pending")
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT attempts FROM rehydrate_queue WHERE session_id = 's'"), 0)
        }
    }

    /// A re-index between bundle capture and commit must abort the offload (no FTS
    /// purge) rather than collapse content that no longer matches the bundle.
    func testCommitOffloadedAbortsWhenSyncVersionChanged() throws {
        let writer = try EngramDatabaseWriter(path: tempDir.appendingPathComponent("toctou.sqlite").path)
        try writer.migrate()
        try writer.write { db in
            try db.execute(sql: """
                INSERT INTO sessions(id, source, start_time, file_path, sync_version)
                VALUES ('s', 'codex', '2024-01-01T00:00:00Z', '/tmp/s.jsonl', 1);
            """)
            for line in ["one", "two", "three"] {
                try db.execute(sql: "INSERT INTO sessions_fts(session_id, content) VALUES ('s', ?)", arguments: [line])
            }
            try OffloadRepo.enqueueOffload(db, sessionIds: ["s"], generation: nil)
        }
        let qid = try writer.read { db in
            try String.fetchOne(db, sql: "SELECT id FROM offload_queue WHERE session_id = 's'")
        }!
        // Simulate a concurrent re-index bumping the version after capture (=1).
        try writer.write { db in try db.execute(sql: "UPDATE sessions SET sync_version = 2 WHERE id = 's'") }

        XCTAssertThrowsError(try writer.write { db in
            try OffloadRepo.commitOffloaded(
                db, queueId: qid, sessionId: "s", expectedSyncVersion: 1,
                remoteKey: "k", contentHash: "h", shadowLine: "shadow", peer: nil
            )
        }) { error in
            guard case RemoteSyncError.offloadStale = error else { return XCTFail("expected offloadStale, got \(error)") }
        }
        try writer.read { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sessions_fts WHERE session_id = 's'"), 3,
                           "stale-version commit must NOT purge FTS")
            XCTAssertEqual(try OffloadRepo.offloadState(db, sessionId: "s"), "local")
        }
    }

    /// Stale `inflight` jobs (crashed/cancelled prior cycle) are reclaimed; a
    /// freshly-claimed one is left alone.
    func testRequeueStaleInflightOnlyResetsOldRows() throws {
        let writer = try EngramDatabaseWriter(path: tempDir.appendingPathComponent("stale.sqlite").path)
        try writer.migrate()
        try writer.write { db in
            try db.execute(sql: "INSERT INTO sessions(id, source, start_time, file_path) VALUES ('s','codex','2024-01-01T00:00:00Z','/tmp/s.jsonl')")
            try db.execute(sql: "INSERT INTO offload_queue(id, session_id, status, updated_at) VALUES ('old', 's', 'inflight', datetime('now','-1 hour'))")
            try db.execute(sql: "INSERT INTO offload_queue(id, session_id, status, updated_at) VALUES ('fresh', 's', 'inflight', datetime('now'))")
        }
        try writer.write { db in _ = try OffloadRepo.requeueStaleInflight(db, olderThanSeconds: 600) }
        try writer.read { db in
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT status FROM offload_queue WHERE id = 'old'"), "pending")
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT status FROM offload_queue WHERE id = 'fresh'"), "inflight")
        }
    }

    /// An imported peer-origin session (offload_state='local', origin=a peer) must
    /// NEVER be picked up by the auto-offload candidate query — re-offloading it would
    /// collapse its imported FTS and insert an 'out' ledger row (an echo loop the
    /// design forbids). A genuine local-origin row is still selected.
    func testCandidateRowsExcludesImportedPeerOrigin() throws {
        let writer = try EngramDatabaseWriter(path: tempDir.appendingPathComponent("origin.sqlite").path)
        try writer.migrate()
        try writer.write { db in
            try db.execute(sql: """
                INSERT INTO sessions(id, source, start_time, file_path, size_bytes, origin)
                VALUES ('local-1', 'codex', '2024-01-01T00:00:00Z', '/tmp/local-1.jsonl', 5000, 'local')
            """)
            try db.execute(sql: """
                INSERT INTO sessions(id, source, start_time, file_path, size_bytes, origin)
                VALUES ('remote:peerB:s9', 'codex', '2024-01-01T00:00:00Z', '/tmp/r.jsonl', 9000, 'peerB')
            """)
        }
        let ids = try writer.read { db in
            try OffloadRepo.candidateRows(db, limit: 100).map(\.id)
        }
        XCTAssertEqual(ids, ["local-1"], "imported peer-origin row must be excluded from offload candidates")
    }

    /// A failed attempt retries (pending) until the cap, then becomes terminal.
    func testFailedOffloadRetriesUntilCap() throws {
        let writer = try EngramDatabaseWriter(path: tempDir.appendingPathComponent("retry.sqlite").path)
        try writer.migrate()
        try writer.write { db in
            try db.execute(sql: "INSERT INTO sessions(id, source, start_time, file_path) VALUES ('s','codex','2024-01-01T00:00:00Z','/tmp/s.jsonl')")
            try OffloadRepo.enqueueOffload(db, sessionIds: ["s"], generation: nil)
        }
        let qid = try writer.read { db in
            try String.fetchOne(db, sql: "SELECT id FROM offload_queue WHERE session_id = 's'")
        }!
        for attempt in 1..<OffloadRepo.maxAttempts {
            try writer.write { db in try OffloadRepo.failOffload(db, queueId: qid, error: "net") }
            let status = try writer.read { db in try String.fetchOne(db, sql: "SELECT status FROM offload_queue WHERE id = ?", arguments: [qid]) }
            XCTAssertEqual(status, "pending", "attempt \(attempt) should retry")
        }
        try writer.write { db in try OffloadRepo.failOffload(db, queueId: qid, error: "net") }
        let final = try writer.read { db in try String.fetchOne(db, sql: "SELECT status FROM offload_queue WHERE id = ?", arguments: [qid]) }
        XCTAssertEqual(final, "failed", "after maxAttempts the job is terminally failed")
    }
}

private struct CancellingRemoteStorageBackend: RemoteStorageBackend {
    enum Operation {
        case put
        case get
    }

    let cancelOn: Operation

    func head(key: String) async throws -> Bool {
        false
    }

    func put(key: String, data: Data) async throws {
        if cancelOn == .put { throw CancellationError() }
    }

    func get(key: String) async throws -> Data {
        if cancelOn == .get { throw CancellationError() }
        return Data()
    }

    func delete(key: String) async throws {}

    func catalog() async throws -> Data {
        Data()
    }
}

private struct ExistingButUnretrievableBackend: RemoteStorageBackend {
    func head(key: String) async throws -> Bool { true }
    func put(key: String, data: Data) async throws {}
    func get(key: String) async throws -> Data {
        throw RemoteSyncError.bundleNotFound(key: key)
    }
    func delete(key: String) async throws {}
    func catalog() async throws -> Data { Data() }
}

private final class ConcurrentRehydrateMutationBackend: RemoteStorageBackend, @unchecked Sendable {
    private let writer: EngramDatabaseWriter
    private let bundle: RemoteSessionBundle

    init(writer: EngramDatabaseWriter, bundle: RemoteSessionBundle) {
        self.writer = writer
        self.bundle = bundle
    }

    func head(key: String) async throws -> Bool {
        true
    }

    func put(key: String, data: Data) async throws {}

    func get(key: String) async throws -> Data {
        try writer.write { db in
            try db.execute(sql: "UPDATE sessions SET sync_version = 2 WHERE id = 's'")
        }
        return try BundleCodec.encode(bundle)
    }

    func delete(key: String) async throws {}

    func catalog() async throws -> Data {
        Data()
    }
}
