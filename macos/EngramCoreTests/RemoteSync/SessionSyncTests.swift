import EngramCoreRead
import EngramCoreWrite
import GRDB
import XCTest

/// Layer 2 (session-record) sync data layer: publish-only ledger writes, manifest
/// build, and idempotent peer import. No schema migration — import state lives on
/// the existing sessions columns (origin / authoritative_node / snapshot_hash).
final class SessionSyncTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("engram-syncrec-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        try super.tearDownWithError()
    }

    private func freshWriter(_ name: String) throws -> EngramDatabaseWriter {
        let writer = try EngramDatabaseWriter(path: tempDir.appendingPathComponent("\(name).sqlite").path)
        try writer.migrate()
        return writer
    }

    private func insertLocalSession(
        _ db: Database, id: String, project: String = "demo", cwd: String = "/Users/bing/-Code-/demo",
        fts: [String] = ["hello", "world"],
        startTime: String = "2024-01-01T00:00:00Z"
    ) throws {
        try db.execute(
            sql: """
            INSERT INTO sessions(id, source, start_time, end_time, cwd, project,
                                 message_count, user_message_count, assistant_message_count,
                                 summary, summary_message_count, generated_title, file_path, size_bytes)
            VALUES (?, 'codex', ?, '2024-01-01T01:00:00Z', ?, ?,
                    2, 1, 1, 'a summary', 2, 'Title', '/tmp/\(id).jsonl', 1234)
            """,
            arguments: [id, startTime, cwd, project]
        )
        for line in fts {
            try db.execute(sql: "INSERT INTO sessions_fts(session_id, content) VALUES (?, ?)", arguments: [id, line])
        }
    }

    // MARK: - publishOnlyCommit

    func testPublishOnlyCommitInsertsOutRowAndPreservesLocalState() throws {
        let writer = try freshWriter("publish")
        try writer.write { db in try insertLocalSession(db, id: "s1") }

        try writer.write { db in
            try OffloadRepo.publishOnlyCommit(
                db, sessionId: "s1", remoteKey: "h1.bundle", remoteSessionId: "s1",
                contentHash: "h1", peer: "macA"
            )
        }
        try writer.read { db in
            let outRows = try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM sync_ledger WHERE session_id = 's1' AND direction = 'out'"
            )
            XCTAssertEqual(outRows, 1, "publish inserts exactly one 'out' ledger row")
            let remoteSession = try String.fetchOne(
                db, sql: "SELECT remote_session_id FROM sync_ledger WHERE session_id = 's1'"
            )
            XCTAssertEqual(remoteSession, "s1")
            // MUST NOT collapse FTS or flip offload_state (unlike commitOffloaded).
            let ftsCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sessions_fts WHERE session_id = 's1'")
            XCTAssertEqual(ftsCount, 2, "publish must NOT collapse local FTS")
            XCTAssertEqual(try OffloadRepo.offloadState(db, sessionId: "s1"), "local",
                           "publish must NOT flip offload_state")
        }
    }

    func testPublishOnlyCommitIsIdempotentPerContentHash() throws {
        let writer = try freshWriter("publish-dedup")
        try writer.write { db in try insertLocalSession(db, id: "s1") }
        try writer.write { db in
            try OffloadRepo.publishOnlyCommit(db, sessionId: "s1", remoteKey: "h1.bundle",
                                              remoteSessionId: "s1", contentHash: "h1", peer: "macA")
            try OffloadRepo.publishOnlyCommit(db, sessionId: "s1", remoteKey: "h1.bundle",
                                              remoteSessionId: "s1", contentHash: "h1", peer: "macA")
        }
        try writer.read { db in
            XCTAssertEqual(
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sync_ledger WHERE session_id = 's1'"), 1,
                "re-publishing the same content hash is a no-op"
            )
        }
        // A new content hash records a new 'out' row.
        try writer.write { db in
            try OffloadRepo.publishOnlyCommit(db, sessionId: "s1", remoteKey: "h2.bundle",
                                              remoteSessionId: "s1", contentHash: "h2", peer: "macA")
        }
        try writer.read { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sync_ledger WHERE session_id = 's1'"), 2)
        }
    }

    func testPublishOnlyCommitScopesIdempotencyByPeer_repro() throws {
        let writer = try freshWriter("publish-peer-scope")
        try writer.write { db in
            try insertLocalSession(db, id: "s1")
            try OffloadRepo.publishOnlyCommit(
                db,
                sessionId: "s1",
                remoteKey: "h1.bundle",
                remoteSessionId: "s1",
                contentHash: "h1",
                peer: "hq"
            )
            try OffloadRepo.publishOnlyCommit(
                db,
                sessionId: "s1",
                remoteKey: "h1.bundle",
                remoteSessionId: "s1",
                contentHash: "h1",
                peer: "macA"
            )
        }

        try writer.read { db in
            XCTAssertEqual(
                try Int.fetchOne(
                    db,
                    sql: """
                    SELECT COUNT(*) FROM sync_ledger
                    WHERE session_id = 's1' AND direction = 'out' AND content_hash = 'h1'
                    """
                ),
                2,
                "the same content must be publishable independently to two peers"
            )
        }
    }

    // MARK: - pushCandidates

    func testPushCandidatesExcludeImportedSkipSubagent() throws {
        let writer = try freshWriter("candidates")
        try writer.write { db in
            try insertLocalSession(db, id: "local-1")
            // imported (origin = a peer) — must be excluded (echo-loop guard)
            try insertLocalSession(db, id: "imported-1")
            try db.execute(sql: "UPDATE sessions SET origin = 'macB' WHERE id = 'imported-1'")
            // skip tier — excluded
            try insertLocalSession(db, id: "skip-1")
            try db.execute(sql: "UPDATE sessions SET tier = 'skip' WHERE id = 'skip-1'")
            // child session — excluded
            try insertLocalSession(db, id: "child-1")
            try db.execute(sql: "UPDATE sessions SET parent_session_id = 'local-1' WHERE id = 'child-1'")
            // already offloaded — excluded (pushing it would republish the collapsed
            // FTS shadow and overwrite the rehydrate ledger key)
            try insertLocalSession(db, id: "offloaded-1")
            try db.execute(sql: "UPDATE sessions SET offload_state = 'offloaded' WHERE id = 'offloaded-1'")
            // subagent by agent_role (tier NOT skip) — excluded (defense-in-depth)
            try insertLocalSession(db, id: "subagent-1")
            try db.execute(sql: "UPDATE sessions SET agent_role = 'subagent' WHERE id = 'subagent-1'")
        }
        let candidates = try writer.read { db in
            try OffloadRepo.pushCandidates(db, project: "demo", cwd: "/Users/bing/-Code-/demo")
        }
        XCTAssertEqual(candidates.map(\.id), ["local-1"],
                       "only local-origin, non-skip, non-subagent, non-offloaded, top-level sessions")
        XCTAssertEqual(candidates.first?.ftsContents, ["hello", "world"])
        XCTAssertEqual(candidates.first?.title, "Title")
    }

    /// OFFLOAD-TOPLEVEL: suggested children are hidden from browse roots and
    /// must not become independent push candidates either.
    func testPushCandidatesExcludeSuggestedParentChildren_repro() throws {
        let writer = try freshWriter("suggested-parent")
        try writer.write { db in
            try insertLocalSession(db, id: "root-1")
            try insertLocalSession(db, id: "suggested-child-1")
            try db.execute(
                sql: "UPDATE sessions SET suggested_parent_id = 'root-1' WHERE id = 'suggested-child-1'"
            )
        }
        let candidates = try writer.read { db in
            try OffloadRepo.pushCandidates(db, project: "demo", cwd: "/Users/bing/-Code-/demo")
        }
        XCTAssertEqual(
            candidates.map(\.id),
            ["root-1"],
            "sessions with suggested_parent_id set must not be push candidates"
        )
    }

    func testPushCandidatesScopeByCaseInsensitiveProjectOrCwd() throws {
        let writer = try freshWriter("scope")
        try writer.write { db in
            // Mismatched-case project but matching cwd → still scoped in.
            try insertLocalSession(db, id: "s1", project: "readout", cwd: "/Users/bing/-Code-/ReadOut")
            // Matching project (case-insensitive), unrelated cwd.
            try insertLocalSession(db, id: "s2", project: "ReadOut", cwd: "/somewhere/else")
            // Unrelated.
            try insertLocalSession(db, id: "s3", project: "other", cwd: "/x")
        }
        let candidates = try writer.read { db in
            try OffloadRepo.pushCandidates(db, project: "ReadOut", cwd: "/Users/bing/-Code-/ReadOut")
        }
        XCTAssertEqual(Set(candidates.map(\.id)), ["s1", "s2"])
    }

    func testPushCandidatesBlankCwdDoesNotOverMatchEmptyCwdSessions() throws {
        let writer = try freshWriter("blank-cwd")
        try writer.write { db in
            // Matching project, empty cwd → still returned via the project-only branch.
            try insertLocalSession(db, id: "match", project: "demo", cwd: "")
            // Unrelated project, empty cwd → must NOT be swept in when the cwd arg is
            // blank (the regression: `cwd = ''` matched every empty-cwd session).
            try insertLocalSession(db, id: "unrelated", project: "other", cwd: "")
        }
        let candidates = try writer.read { db in
            try OffloadRepo.pushCandidates(db, project: "demo", cwd: "")
        }
        XCTAssertEqual(candidates.map(\.id), ["match"],
                       "a blank cwd falls back to project-only matching; empty-cwd sessions of other projects are not over-matched")
    }

    // MARK: - publishedManifestEntries

    func testPublishedManifestEntriesJoinLatestOutLedger() throws {
        let writer = try freshWriter("manifest")
        try writer.write { db in
            try insertLocalSession(db, id: "s1")
            try insertLocalSession(db, id: "s2") // never published → excluded from manifest
            try OffloadRepo.publishOnlyCommit(db, sessionId: "s1", remoteKey: "h1.bundle",
                                              remoteSessionId: "s1", contentHash: "h1", peer: "macA")
            try OffloadRepo.publishOnlyCommit(db, sessionId: "s1", remoteKey: "h2.bundle",
                                              remoteSessionId: "s1", contentHash: "h2", peer: "macA")
        }
        let entries = try writer.read { db in
            try OffloadRepo.publishedManifestEntries(db, project: "demo",
                                                     cwd: "/Users/bing/-Code-/demo", peer: "macA")
        }
        XCTAssertEqual(entries.count, 1, "only published sessions appear")
        let entry = try XCTUnwrap(entries.first)
        XCTAssertEqual(entry.sessionId, "s1")
        XCTAssertEqual(entry.remoteKey, "h2.bundle", "latest 'out' row wins")
        XCTAssertEqual(entry.contentHash, "h2")
        XCTAssertEqual(entry.title, "Title")
        XCTAssertEqual(entry.messageCount, 2)
    }

    func testPublishedManifestEntriesNormalizeProjectToRequested() throws {
        let writer = try freshWriter("manifest-normalize")
        try writer.write { db in
            // cwd-matched session whose stored project is blank/divergent from the
            // requested name — its entry must carry the REQUESTED project so the
            // pull side (which matches on project name only, no cwd) can find it.
            try insertLocalSession(db, id: "s1", project: "", cwd: "/Users/bing/-Code-/ReadOut")
            try OffloadRepo.publishOnlyCommit(db, sessionId: "s1", remoteKey: "h1.bundle",
                                              remoteSessionId: "s1", contentHash: "h1", peer: "macA")
        }
        let entries = try writer.read { db in
            try OffloadRepo.publishedManifestEntries(db, project: "ReadOut",
                                                     cwd: "/Users/bing/-Code-/ReadOut", peer: "macA")
        }
        XCTAssertEqual(entries.map(\.project), ["ReadOut"],
                       "cwd-only-matched entry project is normalized to the requested name (importable on pull)")
    }

    func testPublishedManifestEntriesRetractSessionsThatBecameSkipOrChildren_repro() throws {
        let writer = try freshWriter("manifest-retract")
        try writer.write { db in
            for id in ["skip", "child", "suggested", "subagent", "visible"] {
                try insertLocalSession(db, id: id)
                try OffloadRepo.publishOnlyCommit(
                    db,
                    sessionId: id,
                    remoteKey: "\(id).bundle",
                    remoteSessionId: id,
                    contentHash: id,
                    peer: "macA"
                )
            }
            try db.execute(sql: "UPDATE sessions SET tier = 'skip' WHERE id = 'skip'")
            try db.execute(sql: "UPDATE sessions SET parent_session_id = 'visible' WHERE id = 'child'")
            try db.execute(sql: "UPDATE sessions SET suggested_parent_id = 'visible' WHERE id = 'suggested'")
            try db.execute(sql: "UPDATE sessions SET agent_role = 'subagent' WHERE id = 'subagent'")
        }

        let entries = try writer.read { db in
            try OffloadRepo.publishedManifestEntries(
                db,
                project: "demo",
                cwd: "/Users/bing/-Code-/demo",
                peer: "macA"
            )
        }

        XCTAssertEqual(entries.map(\.sessionId), ["visible"])
    }

    // MARK: - live publish candidates / assembly

    func testLivePublishCandidatesOmitSkipSubagentSuggestedParent_repro() throws {
        let writer = try freshWriter("live-candidates")
        try writer.write { db in
            try insertLocalSession(db, id: "local-1")
            try insertLocalSession(db, id: "imported-1")
            try db.execute(sql: "UPDATE sessions SET origin = 'hq' WHERE id = 'imported-1'")
            try insertLocalSession(db, id: "skip-1")
            try db.execute(sql: "UPDATE sessions SET tier = 'skip' WHERE id = 'skip-1'")
            try insertLocalSession(db, id: "child-1")
            try db.execute(sql: "UPDATE sessions SET parent_session_id = 'local-1' WHERE id = 'child-1'")
            try insertLocalSession(db, id: "suggested-1")
            try db.execute(sql: "UPDATE sessions SET suggested_parent_id = 'local-1' WHERE id = 'suggested-1'")
            try insertLocalSession(db, id: "offloaded-1")
            try db.execute(sql: "UPDATE sessions SET offload_state = 'offloaded' WHERE id = 'offloaded-1'")
            try insertLocalSession(db, id: "subagent-1")
            try db.execute(sql: "UPDATE sessions SET agent_role = 'subagent' WHERE id = 'subagent-1'")
            try insertLocalSession(db, id: "other-project", project: "other")
        }
        let candidates = try writer.read { db in
            try OffloadRepo.livePublishCandidates(db, limit: 50)
        }
        XCTAssertEqual(
            Set(candidates.map(\.id)),
            ["local-1", "other-project"],
            "live candidates are project-unscoped but still omit skip/child/offloaded/imported"
        )
    }

    func testPublishCandidatesExcludeDispatchedAgentRole_repro() throws {
        let writer = try freshWriter("dispatched-publish")
        try writer.write { db in
            try insertLocalSession(db, id: "visible")
            try insertLocalSession(db, id: "dispatched")
            try db.execute(sql: "UPDATE sessions SET agent_role = 'dispatched' WHERE id = 'dispatched'")
            for id in ["visible", "dispatched"] {
                try OffloadRepo.publishOnlyCommit(
                    db,
                    sessionId: id,
                    remoteKey: "\(id).bundle",
                    remoteSessionId: id,
                    contentHash: id,
                    peer: "hq"
                )
            }
        }

        try writer.read { db in
            XCTAssertEqual(
                try OffloadRepo.pushCandidates(
                    db,
                    project: "demo",
                    cwd: "/Users/bing/-Code-/demo"
                ).map(\.id),
                ["visible"]
            )
            XCTAssertEqual(try OffloadRepo.livePublishCandidates(db, limit: 50).map(\.id), ["visible"])
            XCTAssertEqual(
                try OffloadRepo.publishedManifestEntries(
                    db,
                    project: "demo",
                    cwd: "/Users/bing/-Code-/demo",
                    peer: "hq"
                ).map(\.sessionId),
                ["visible"]
            )
            XCTAssertEqual(try OffloadRepo.livePublishedEntries(db, peer: "hq").map(\.sessionId), ["visible"])
        }
    }

    func testLivePublishCandidatesPageByStartTimeThenId_repro() throws {
        let writer = try freshWriter("live-page")
        try writer.write { db in
            try insertLocalSession(db, id: "m-b", startTime: "2024-01-01T00:00:00Z")
            try insertLocalSession(db, id: "late", startTime: "2024-01-02T00:00:00Z")
            try insertLocalSession(db, id: "early", startTime: "2023-12-01T00:00:00Z")
            try insertLocalSession(db, id: "m-a", startTime: "2024-01-01T00:00:00Z")
        }
        let first = try writer.read { db in
            try OffloadRepo.livePublishCandidates(db, limit: 2)
        }
        XCTAssertEqual(first.map(\.id), ["early", "m-a"], "first page is (start_time, id), not start_time alone")
        let second = try writer.read { db in
            try OffloadRepo.livePublishCandidates(
                db, limit: 2, afterStart: first.last?.startTime, afterId: first.last?.id
            )
        }
        XCTAssertEqual(
            second.map(\.id),
            ["m-b", "late"],
            "same start_time must not drop the next id"
        )
    }

    func testLivePublishFtsFenceRequiresCompletedCurrentTargetOrNoJob_repro() throws {
        let blockedStatuses = [
            "pending", "running", "failed_retryable", "failed_permanent",
            "failed_terminal", "failed", "not_applicable",
        ]
        for status in blockedStatuses {
            let writer = try freshWriter("live-fts-fence-\(status)")
            try writer.write { db in
                try insertLocalSession(db, id: "s1")
                try db.execute(sql: "UPDATE sessions SET sync_version = 7 WHERE id = 's1'")
                try db.execute(
                    sql: """
                    INSERT INTO session_index_jobs(id, session_id, job_kind, target_sync_version, status)
                    VALUES (?, 's1', 'fts', 7, ?)
                    """,
                    arguments: ["s1:7:\(status):fts", status]
                )
            }

            let candidates = try writer.read { db in
                try OffloadRepo.livePublishCandidates(db, limit: 1, peer: "hq")
            }
            XCTAssertEqual(candidates, [], "\(status) must not consume a ready publish page")
            XCTAssertTrue(try writer.read { db in
                try OffloadRepo.hasUnreadyLivePublishCandidates(db)
            })
            let committed = try writer.write { db in
                try OffloadRepo.commitLivePublishedSnapshot(
                    db,
                    sessionId: "s1",
                    remoteKey: "blocked.bundle",
                    contentHash: "blocked",
                    peer: "hq",
                    expectedSyncVersion: 7,
                    expectedSnapshotHash: ""
                )
            }
            XCTAssertFalse(committed, "\(status) must not certify a live snapshot")
        }

        let completed = try freshWriter("live-fts-fence-completed")
        try completed.write { db in
            try insertLocalSession(db, id: "s1")
            try db.execute(sql: "UPDATE sessions SET sync_version = 7 WHERE id = 's1'")
            try db.execute(
                sql: """
                INSERT INTO session_index_jobs(id, session_id, job_kind, target_sync_version, status)
                VALUES ('s1:6:old:fts', 's1', 'fts', 6, 'failed_permanent'),
                       ('s1:7:current:fts', 's1', 'fts', 7, 'completed')
                """
            )
        }
        let completedCandidate = try XCTUnwrap(try completed.read { db in
            try OffloadRepo.livePublishCandidates(db, limit: 1, peer: "hq").first
        })
        XCTAssertTrue(completedCandidate.ftsSnapshotReady)
        XCTAssertEqual(completedCandidate.ftsContents, ["hello", "world"])
        XCTAssertFalse(try completed.read { db in
            try OffloadRepo.hasUnreadyLivePublishCandidates(db)
        })
        XCTAssertTrue(try completed.write { db in
            try OffloadRepo.commitLivePublishedSnapshot(
                db,
                sessionId: "s1",
                remoteKey: "completed.bundle",
                contentHash: "completed",
                peer: "hq",
                expectedSyncVersion: 7,
                expectedSnapshotHash: ""
            )
        })

        let wrongTarget = try freshWriter("live-fts-fence-wrong-target")
        try wrongTarget.write { db in
            try insertLocalSession(db, id: "s1")
            try db.execute(sql: "UPDATE sessions SET sync_version = 7 WHERE id = 's1'")
            try db.execute(
                sql: """
                INSERT INTO session_index_jobs(id, session_id, job_kind, target_sync_version, status)
                VALUES ('s1:6:old:fts', 's1', 'fts', 6, 'completed')
                """
            )
        }
        XCTAssertEqual(try wrongTarget.read { db in
            try OffloadRepo.livePublishCandidates(db, limit: 1, peer: "hq")
        }, [])
        XCTAssertTrue(try wrongTarget.read { db in
            try OffloadRepo.hasUnreadyLivePublishCandidates(db)
        })
        XCTAssertFalse(try wrongTarget.write { db in
            try OffloadRepo.commitLivePublishedSnapshot(
                db,
                sessionId: "s1",
                remoteKey: "wrong-target.bundle",
                contentHash: "wrong-target",
                peer: "hq",
                expectedSyncVersion: 7,
                expectedSnapshotHash: ""
            )
        })

        let legacy = try freshWriter("live-fts-fence-legacy")
        try legacy.write { db in
            try insertLocalSession(db, id: "s1")
            try db.execute(sql: "UPDATE sessions SET sync_version = 7 WHERE id = 's1'")
        }
        let legacyCandidate = try XCTUnwrap(try legacy.read { db in
            try OffloadRepo.livePublishCandidates(db, limit: 1, peer: "hq").first
        })
        XCTAssertTrue(legacyCandidate.ftsSnapshotReady)
        XCTAssertEqual(legacyCandidate.ftsContents, ["hello", "world"])
        XCTAssertFalse(try legacy.read { db in
            try OffloadRepo.hasUnreadyLivePublishCandidates(db)
        })
        XCTAssertTrue(try legacy.write { db in
            try OffloadRepo.commitLivePublishedSnapshot(
                db,
                sessionId: "s1",
                remoteKey: "legacy.bundle",
                contentHash: "legacy",
                peer: "hq",
                expectedSyncVersion: 7,
                expectedSnapshotHash: ""
            )
        })
    }

    func testLivePublishLegacyLedgerWithoutSnapshotHashRepublishesOnce_repro() throws {
        let writer = try freshWriter("live-legacy-snapshot-fence")
        try writer.write { db in
            try insertLocalSession(db, id: "s1")
            try db.execute(
                sql: "UPDATE sessions SET sync_version = 7, snapshot_hash = 'snapshot-v7' WHERE id = 's1'"
            )
            try db.execute(
                sql: """
                INSERT INTO sync_ledger(
                    session_id, remote_peer, remote_session_id, remote_key,
                    direction, content_hash, source_sync_version
                ) VALUES ('s1', 'hq', 's1', 'legacy.bundle', 'out', 'legacy-content', 7)
                """
            )
        }

        let legacyCandidate = try XCTUnwrap(try writer.read { db in
            try OffloadRepo.livePublishCandidates(
                db,
                limit: 1,
                peer: "hq",
                onlyChanged: true
            ).first
        })
        XCTAssertFalse(legacyCandidate.bundleIsCurrent)
        XCTAssertEqual(legacyCandidate.ftsContents, ["hello", "world"])

        XCTAssertTrue(try writer.write { db in
            try OffloadRepo.commitLivePublishedSnapshot(
                db,
                sessionId: "s1",
                remoteKey: "current.bundle",
                contentHash: "current-content",
                peer: "hq",
                expectedSyncVersion: 7,
                expectedSnapshotHash: "snapshot-v7"
            )
        })
        XCTAssertEqual(
            try writer.read { db in
                try OffloadRepo.livePublishCandidates(
                    db,
                    limit: 1,
                    peer: "hq",
                    includeFtsContents: false,
                    onlyChanged: true
                ).map(\.id)
            },
            [],
            "after one safe republish the migrated ledger must become current"
        )
    }

    func testLivePublishDeltaOnlyTracksReadyChangesAndPublishedRetractions_repro() throws {
        let writer = try freshWriter("live-publish-delta")
        try writer.write { db in
            try insertLocalSession(db, id: "skip")
            try db.execute(sql: "UPDATE sessions SET tier = 'skip' WHERE id = 'skip'")
            try insertLocalSession(db, id: "imported")
            try db.execute(sql: "UPDATE sessions SET origin = 'hq' WHERE id = 'imported'")
            try insertLocalSession(db, id: "unready")
            try db.execute(sql: """
                UPDATE sessions SET sync_version = 1, snapshot_hash = 'unready-v1'
                WHERE id = 'unready';
                INSERT INTO session_index_jobs(id, session_id, job_kind, target_sync_version, status)
                VALUES ('unready:1:fts', 'unready', 'fts', 1, 'pending');
                """)
        }

        XCTAssertFalse(try writer.read { db in
            try OffloadRepo.hasLivePublishDelta(db, peer: "hq")
        }, "skip, imported, and current-FTS-unready rows must not wake the publisher")

        try writer.write { db in
            try insertLocalSession(db, id: "ready")
            try db.execute(sql: """
                UPDATE sessions SET sync_version = 1, snapshot_hash = 'ready-v1'
                WHERE id = 'ready'
                """)
        }
        XCTAssertTrue(try writer.read { db in
            try OffloadRepo.hasLivePublishDelta(db, peer: "hq")
        }, "a changed ready publish candidate must wake the publisher")

        XCTAssertTrue(try writer.write { db in
            try OffloadRepo.commitLivePublishedSnapshot(
                db,
                sessionId: "ready",
                remoteKey: "ready.bundle",
                contentHash: "ready-content",
                peer: "hq",
                expectedSyncVersion: 1,
                expectedSnapshotHash: "ready-v1"
            )
        })
        XCTAssertFalse(try writer.read { db in
            try OffloadRepo.hasLivePublishDelta(db, peer: "hq")
        }, "a current published row plus unrelated unready noise is idle")

        try writer.write { db in
            try db.execute(sql: """
                INSERT INTO session_index_jobs(id, session_id, job_kind, target_sync_version, status)
                VALUES ('ready:1:fts', 'ready', 'fts', 1, 'pending')
                """)
        }
        XCTAssertFalse(try writer.read { db in
            try OffloadRepo.hasLivePublishDelta(db, peer: "hq")
        }, "temporary FTS unreadiness must not be mistaken for a manifest retract")

        try writer.write { db in
            try db.execute(sql: "UPDATE sessions SET tier = 'skip' WHERE id = 'ready'")
        }
        XCTAssertTrue(try writer.read { db in
            try OffloadRepo.hasLivePublishDelta(db, peer: "hq")
        }, "a previously published member becoming ineligible must wake a retract publish")
    }

    func testLivePublishedEntriesJoinAllLedgerRowsNotLastBatch_repro() throws {
        let writer = try freshWriter("live-assembly")
        try writer.write { db in
            try insertLocalSession(db, id: "a", project: "Alpha", startTime: "2024-01-01T00:00:00Z")
            try insertLocalSession(db, id: "b", project: "Beta", startTime: "2024-01-02T00:00:00Z")
            try insertLocalSession(db, id: "c", project: "Gamma", startTime: "2024-01-03T00:00:00Z")
            try insertLocalSession(db, id: "never-published")
            try insertLocalSession(db, id: "became-skip")
            try insertLocalSession(db, id: "became-offloaded")
            try insertLocalSession(db, id: "imported-echo")
            try db.execute(sql: "UPDATE sessions SET origin = 'macB' WHERE id = 'imported-echo'")
            for id in ["a", "b", "c", "became-skip", "became-offloaded", "imported-echo"] {
                try OffloadRepo.publishOnlyCommit(
                    db, sessionId: id, remoteKey: "\(id).bundle",
                    remoteSessionId: id, contentHash: "\(id)-h1", peer: "hq"
                )
            }
            try OffloadRepo.publishOnlyCommit(
                db, sessionId: "a", remoteKey: "a-old.bundle",
                remoteSessionId: "a", contentHash: "a-old", peer: "macA"
            )
            try OffloadRepo.publishOnlyCommit(
                db, sessionId: "a", remoteKey: "a-h2.bundle",
                remoteSessionId: "a", contentHash: "a-h2", peer: "hq"
            )
            try db.execute(sql: "UPDATE sessions SET tier = 'skip' WHERE id = 'became-skip'")
            try db.execute(sql: "UPDATE sessions SET offload_state = 'offloaded' WHERE id = 'became-offloaded'")
        }
        let lastBatch = try writer.read { db in
            try OffloadRepo.livePublishCandidates(db, limit: 1)
        }
        XCTAssertEqual(lastBatch.map(\.id), ["a"])
        let entries = try writer.read { db in
            try OffloadRepo.livePublishedEntries(db, peer: "hq")
        }
        XCTAssertEqual(entries.map(\.sessionId), ["a", "b", "c"], "assembly is the full ledger join, not the last batch")
        XCTAssertEqual(entries.map(\.project), ["Alpha", "Beta", "Gamma"], "must not rewrite project")
        XCTAssertEqual(entries.first?.remoteKey, "a-h2.bundle", "latest hq out row wins")
        XCTAssertEqual(entries.first?.contentHash, "a-h2")
        XCTAssertFalse(entries.contains { $0.sessionId == "became-skip" })
        XCTAssertFalse(entries.contains { $0.sessionId == "became-offloaded" })
        XCTAssertFalse(entries.contains { $0.sessionId == "imported-echo" })
        XCTAssertFalse(entries.contains { $0.remoteKey == "a-old.bundle" })
    }

    func testLivePublishLedgerCompactionKeepsLatestOutRow_repro() throws {
        let writer = try freshWriter("live-compact")
        try writer.write { db in
            try insertLocalSession(db, id: "s1")
            try insertLocalSession(db, id: "s2")
            try OffloadRepo.publishOnlyCommit(
                db, sessionId: "s1", remoteKey: "s1-h1.bundle",
                remoteSessionId: "s1", contentHash: "s1-h1", peer: "hq"
            )
            try OffloadRepo.publishOnlyCommit(
                db, sessionId: "s1", remoteKey: "s1-h2.bundle",
                remoteSessionId: "s1", contentHash: "s1-h2", peer: "hq"
            )
            try OffloadRepo.publishOnlyCommit(
                db, sessionId: "s1", remoteKey: "s1-mac.bundle",
                remoteSessionId: "s1", contentHash: "s1-mac", peer: "macA"
            )
            try OffloadRepo.publishOnlyCommit(
                db, sessionId: "s2", remoteKey: "s2-h1.bundle",
                remoteSessionId: "s2", contentHash: "s2-h1", peer: "hq"
            )
            try OffloadRepo.compactLivePublishLedger(db, peer: "hq", sessionId: "s1")
        }
        try writer.read { db in
            let hqS1 = try String.fetchAll(
                db,
                sql: """
                SELECT content_hash FROM sync_ledger
                WHERE session_id = 's1' AND remote_peer = 'hq' AND direction = 'out'
                ORDER BY content_hash
                """
            )
            XCTAssertEqual(hqS1, ["s1-h2"], "live compaction drops older hq out rows only")
            XCTAssertEqual(
                try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM sync_ledger WHERE session_id = 's1' AND remote_peer = 'macA'"
                ),
                1,
                "other-peer ledger rows stay"
            )
            XCTAssertEqual(
                try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM sync_ledger WHERE session_id = 's2' AND remote_peer = 'hq'"
                ),
                1,
                "other sessions are not compacted"
            )
        }
    }

    // MARK: - ImportRepo

    private func makeEntryAndBundle(
        sessionId: String, peer _: String, hash: String, fts: [String]
    ) -> (SyncManifestEntry, RemoteSessionBundle) {
        let bundle = BundleCodec.makeBundle(
            sessionId: sessionId, ftsContents: fts, summary: "remote summary", summaryMessageCount: 2,
            messageCount: 2, userMessageCount: 1, assistantMessageCount: 1,
            toolMessageCount: 0, systemMessageCount: 0
        )
        let entry = SyncManifestEntry(
            sessionId: sessionId, source: "codex", project: "demo", title: "Remote Title",
            startTime: "2024-02-02T00:00:00Z", endTime: "2024-02-02T01:00:00Z",
            messageCount: 2, userMessageCount: 1, assistantMessageCount: 1,
            systemMessageCount: 0, toolMessageCount: 0, summary: "entry summary",
            summaryMessageCount: 2, sizeBytes: 4096, tier: "normal",
            remoteKey: "\(hash).bundle", contentHash: hash
        )
        return (entry, bundle)
    }

    func testCommitImportedCreatesSearchableRowWithPeerOrigin() throws {
        let writer = try freshWriter("import")
        let (entry, bundle) = makeEntryAndBundle(
            sessionId: "rs1", peer: "macB", hash: "ih1", fts: ["alpha bravo", "charlie delta"]
        )
        try writer.write { db in try ImportRepo.commitImported(db, entry: entry, peer: "macB", bundle: bundle) }

        let localId = ImportRepo.importedLocalId(peer: "macB", sessionId: "rs1")
        XCTAssertEqual(localId, "remote:macB:rs1")
        try writer.read { db in
            let row = try XCTUnwrap(try Row.fetchOne(
                db, sql: "SELECT origin, authoritative_node, snapshot_hash, summary, file_path, offload_state, cwd, generated_title FROM sessions WHERE id = ?",
                arguments: [localId]
            ))
            XCTAssertEqual(row["origin"], "macB")
            XCTAssertEqual(row["authoritative_node"], "macB")
            XCTAssertEqual(row["snapshot_hash"], "ih1")
            XCTAssertEqual(row["summary"], "remote summary", "bundle summary wins over entry summary")
            XCTAssertEqual(row["file_path"], "remote://macB/rs1")
            XCTAssertEqual(row["offload_state"], "local")
            XCTAssertEqual(row["cwd"], "")
            XCTAssertEqual(row["generated_title"], "Remote Title")
            // searchable: imported FTS content present
            let hits = try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM sessions_fts WHERE session_id = ? AND content MATCH 'bravo'",
                arguments: [localId]
            )
            XCTAssertEqual(hits, 1, "imported session is keyword searchable")
        }
    }

    func testCommitImportedIsIdempotentAndUpdatesInPlace() throws {
        let writer = try freshWriter("import-idem")
        let (entry, bundle) = makeEntryAndBundle(sessionId: "rs1", peer: "macB", hash: "ih1", fts: ["one two"])
        let localId = ImportRepo.importedLocalId(peer: "macB", sessionId: "rs1")

        try writer.write { db in try ImportRepo.commitImported(db, entry: entry, peer: "macB", bundle: bundle) }
        // Re-import same hash → no duplicate, single row.
        try writer.write { db in try ImportRepo.commitImported(db, entry: entry, peer: "macB", bundle: bundle) }
        try writer.read { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sessions WHERE id = ?", arguments: [localId]), 1)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sessions_fts WHERE session_id = ?", arguments: [localId]), 1)
        }
        // Different hash → updates in place (new title + FTS), still one row.
        let (entry2, bundle2) = makeEntryAndBundle(sessionId: "rs1", peer: "macB", hash: "ih2", fts: ["three four", "five six"])
        let updated = SyncManifestEntry(
            sessionId: entry2.sessionId, source: entry2.source, project: entry2.project, title: "Updated Title",
            startTime: entry2.startTime, endTime: entry2.endTime, messageCount: entry2.messageCount,
            userMessageCount: entry2.userMessageCount, assistantMessageCount: entry2.assistantMessageCount,
            systemMessageCount: entry2.systemMessageCount, toolMessageCount: entry2.toolMessageCount,
            summary: entry2.summary, summaryMessageCount: entry2.summaryMessageCount, sizeBytes: entry2.sizeBytes,
            tier: entry2.tier, remoteKey: entry2.remoteKey, contentHash: entry2.contentHash
        )
        try writer.write { db in try ImportRepo.commitImported(db, entry: updated, peer: "macB", bundle: bundle2) }
        try writer.read { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sessions WHERE id = ?", arguments: [localId]), 1,
                           "re-import updates in place, no duplicate row")
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT snapshot_hash FROM sessions WHERE id = ?", arguments: [localId]), "ih2")
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT generated_title FROM sessions WHERE id = ?", arguments: [localId]), "Updated Title")
            let restored = Set(try String.fetchAll(db, sql: "SELECT content FROM sessions_fts WHERE session_id = ?", arguments: [localId]))
            XCTAssertEqual(restored, Set(["three four", "five six"]), "FTS replaced with new content")
        }
    }

    /// The load-bearing invariant: re-import must UPSERT (UPDATE in place), NOT
    /// `INSERT OR REPLACE` (delete-then-insert), so a session's ON DELETE CASCADE
    /// children survive every re-pull. Plants a `session_local_state` child and
    /// asserts it survives a changed-hash re-import. Fails immediately under REPLACE.
    func testCommitImportedPreservesCascadeChildrenOnReimport() throws {
        let writer = try freshWriter("import-cascade")
        let (entry, bundle) = makeEntryAndBundle(sessionId: "rs1", peer: "macB", hash: "ih1", fts: ["one"])
        let localId = ImportRepo.importedLocalId(peer: "macB", sessionId: "rs1")

        try writer.write { db in try ImportRepo.commitImported(db, entry: entry, peer: "macB", bundle: bundle) }
        // Plant an ON DELETE CASCADE child keyed by the imported row.
        try writer.write { db in
            try db.execute(
                sql: "INSERT INTO session_local_state(session_id, custom_name) VALUES (?, 'pinned')",
                arguments: [localId]
            )
        }
        // Re-import with a CHANGED hash → row updated in place; the child must survive.
        let (entry2, bundle2) = makeEntryAndBundle(sessionId: "rs1", peer: "macB", hash: "ih2", fts: ["two"])
        try writer.write { db in try ImportRepo.commitImported(db, entry: entry2, peer: "macB", bundle: bundle2) }
        try writer.read { db in
            XCTAssertEqual(
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM session_local_state WHERE session_id = ?", arguments: [localId]),
                1, "UPSERT must preserve cascade children; INSERT OR REPLACE would delete them"
            )
            XCTAssertEqual(
                try String.fetchOne(db, sql: "SELECT custom_name FROM session_local_state WHERE session_id = ?", arguments: [localId]),
                "pinned", "child row content intact across re-import"
            )
            XCTAssertEqual(
                try String.fetchOne(db, sql: "SELECT snapshot_hash FROM sessions WHERE id = ?", arguments: [localId]),
                "ih2", "session row itself updated in place"
            )
        }
    }

    func testNeedsImportLogic() throws {
        let writer = try freshWriter("needs")
        let (entry, bundle) = makeEntryAndBundle(sessionId: "rs1", peer: "macB", hash: "ih1", fts: ["x"])
        try writer.read { db in
            XCTAssertTrue(try ImportRepo.needsImport(db, peer: "macB", entry: entry), "never imported → needs import")
        }
        try writer.write { db in try ImportRepo.commitImported(db, entry: entry, peer: "macB", bundle: bundle) }
        try writer.read { db in
            XCTAssertFalse(try ImportRepo.needsImport(db, peer: "macB", entry: entry), "same hash → no import")
        }
        let changed = SyncManifestEntry(
            sessionId: entry.sessionId, source: entry.source, project: entry.project, title: entry.title,
            startTime: entry.startTime, endTime: entry.endTime, messageCount: entry.messageCount,
            userMessageCount: entry.userMessageCount, assistantMessageCount: entry.assistantMessageCount,
            systemMessageCount: entry.systemMessageCount, toolMessageCount: entry.toolMessageCount,
            summary: entry.summary, summaryMessageCount: entry.summaryMessageCount, sizeBytes: entry.sizeBytes,
            tier: entry.tier, remoteKey: "ih9.bundle", contentHash: "ih9"
        )
        try writer.read { db in
            XCTAssertTrue(try ImportRepo.needsImport(db, peer: "macB", entry: changed), "different hash → needs re-import")
        }
    }

    func testLivePullSkipsWhenLocalOriginAlreadyOwnsNativeId_repro() throws {
        let writer = try freshWriter("occupancy")
        try writer.write { db in
            try insertLocalSession(db, id: "native-1")
            try insertLocalSession(db, id: "skip-native")
            try db.execute(sql: "UPDATE sessions SET tier = 'skip' WHERE id = 'skip-native'")
            try insertLocalSession(db, id: "hidden-native")
            try db.execute(sql: "UPDATE sessions SET hidden_at = datetime('now') WHERE id = 'hidden-native'")
            try insertLocalSession(db, id: "explicit-local")
            try db.execute(sql: "UPDATE sessions SET origin = 'local' WHERE id = 'explicit-local'")
            let (entry, bundle) = makeEntryAndBundle(sessionId: "imported-only", peer: "hq", hash: "ih1", fts: ["x"])
            try ImportRepo.commitImported(db, entry: entry, peer: "hq", bundle: bundle)
        }
        try writer.read { db in
            XCTAssertTrue(try ImportRepo.localOriginOccupiesNativeId(db, nativeSessionId: "native-1"))
            XCTAssertTrue(
                try ImportRepo.localOriginOccupiesNativeId(db, nativeSessionId: "skip-native"),
                "skip occupants still occupy the native id"
            )
            XCTAssertTrue(
                try ImportRepo.localOriginOccupiesNativeId(db, nativeSessionId: "hidden-native"),
                "hidden local rows still occupy the native id"
            )
            XCTAssertTrue(try ImportRepo.localOriginOccupiesNativeId(db, nativeSessionId: "explicit-local"))
            XCTAssertFalse(
                try ImportRepo.localOriginOccupiesNativeId(db, nativeSessionId: "imported-only"),
                "an imported remote:hq:… row is not a local-origin occupant of the native id"
            )
            XCTAssertFalse(try ImportRepo.localOriginOccupiesNativeId(db, nativeSessionId: "missing"))
        }
    }

    func testLivePullRetractsWhenCompleteManifestDropsSkip_repro() throws {
        let writer = try freshWriter("peer-retract")
        let (keep, keepBundle) = makeEntryAndBundle(sessionId: "keep-1", peer: "hq", hash: "kh1", fts: ["keep term"])
        let (drop, dropBundle) = makeEntryAndBundle(sessionId: "drop-1", peer: "hq", hash: "dh1", fts: ["drop term"])
        let (other, otherBundle) = makeEntryAndBundle(sessionId: "other-1", peer: "macB", hash: "oh1", fts: ["other term"])
        try writer.write { db in
            try ImportRepo.commitImported(db, entry: keep, peer: "hq", bundle: keepBundle)
            try ImportRepo.commitImported(db, entry: drop, peer: "hq", bundle: dropBundle)
            try ImportRepo.commitImported(db, entry: other, peer: "macB", bundle: otherBundle)
            try insertLocalSession(db, id: "local-1", fts: ["local term"])
        }
        let keepId = ImportRepo.importedLocalId(peer: "hq", sessionId: "keep-1")
        let dropId = ImportRepo.importedLocalId(peer: "hq", sessionId: "drop-1")
        let otherId = ImportRepo.importedLocalId(peer: "macB", sessionId: "other-1")

        let removed = try writer.write { db in
            try ImportRepo.retractImportedPeerSessions(db, peer: "hq", retainingRemoteSessionIds: ["keep-1"])
        }
        XCTAssertEqual(removed, 1)
        try writer.read { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sessions WHERE id = ?", arguments: [keepId]), 1)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sessions WHERE id = ?", arguments: [dropId]), 0)
            XCTAssertEqual(
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sessions_fts WHERE session_id = ?", arguments: [dropId]),
                0,
                "FTS must be cleared before the imported row is deleted"
            )
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sessions WHERE id = ?", arguments: [otherId]), 1,
                           "other-peer imports are outside this retract")
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sessions WHERE id = 'local-1'"), 1)
        }
    }

    func testLivePullDoesNotRetractLocalOrigin_repro() throws {
        let writer = try freshWriter("no-local-retract")
        try writer.write { db in
            try insertLocalSession(db, id: "null-origin")
            try insertLocalSession(db, id: "local-origin")
            try db.execute(sql: "UPDATE sessions SET origin = 'local' WHERE id = 'local-origin'")
            let (entry, bundle) = makeEntryAndBundle(sessionId: "hq-1", peer: "hq", hash: "ih1", fts: ["hq term"])
            try ImportRepo.commitImported(db, entry: entry, peer: "hq", bundle: bundle)
        }
        let removed = try writer.write { db in
            try ImportRepo.retractImportedPeerSessions(db, peer: "hq", retainingRemoteSessionIds: [])
        }
        XCTAssertEqual(removed, 1)
        try writer.read { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sessions WHERE id = 'null-origin'"), 1)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sessions WHERE id = 'local-origin'"), 1)
            XCTAssertEqual(
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sessions WHERE origin = 'hq'"),
                0
            )
        }
    }

    // MARK: - ManifestCodec

    func testBundleHashIncludesTierAndParentVisibilityMetadata_repro() throws {
        func bundle(
            tier: String? = nil,
            agentRole: String? = nil,
            parentSessionId: String? = nil,
            suggestedParentId: String? = nil
        ) -> RemoteSessionBundle {
            BundleCodec.makeBundle(
                sessionId: "visibility",
                ftsContents: ["same content"],
                summary: nil,
                summaryMessageCount: nil,
                messageCount: 1,
                userMessageCount: 1,
                assistantMessageCount: 0,
                toolMessageCount: 0,
                systemMessageCount: 0,
                tier: tier,
                agentRole: agentRole,
                parentSessionId: parentSessionId,
                suggestedParentId: suggestedParentId
            )
        }

        let visible = bundle(tier: "normal")
        let skip = bundle(tier: "skip")
        let child = bundle(tier: "normal", parentSessionId: "parent")
        let suggested = bundle(tier: "normal", suggestedParentId: "suggested-parent")
        let subagent = bundle(tier: "normal", agentRole: "subagent")

        XCTAssertEqual(Set([visible, skip, child, suggested, subagent].map(\.contentHash)).count, 5)
        XCTAssertEqual(try BundleCodec.decode(BundleCodec.encode(child)), child)
    }

    func testLiveIngestKeysAreValidAndNotCatalogManifests_repro() throws {
        let head = LiveIngestKeys.head(peer: "hq")
        let manifest = LiveIngestKeys.manifest(peer: "hq", generation: 3, seq: 11)
        XCTAssertEqual(head, "live.hq.head")
        XCTAssertEqual(manifest, "live.hq.3.11.manifest")
        XCTAssertNoThrow(try RemoteStorageKey.validate(head))
        XCTAssertNoThrow(try RemoteStorageKey.validate(manifest))
        XCTAssertFalse(ManifestCodec.isManifestKey(head), "live head must stay out of GET /v1/catalog")
        XCTAssertFalse(ManifestCodec.isManifestKey(manifest), "live generation blobs must stay out of GET /v1/catalog")
        XCTAssertTrue(ManifestCodec.isManifestKey(ManifestCodec.manifestKey(peer: "hq")))
        let odd = LiveIngestKeys.head(peer: "hq/foo")
        XCTAssertNoThrow(try RemoteStorageKey.validate(odd))
        XCTAssertFalse(odd.contains("/"))
    }

    func testLiveIngestHeadAndManifestRoundTrip_repro() throws {
        let (entry, _) = makeEntryAndBundle(sessionId: "rs1", peer: "hq", hash: "ih1", fts: ["x"])
        let manifest = SyncManifest(peer: "hq", updatedAt: "2024-02-02T00:00:00Z", entries: [entry])
        let manifestData = try ManifestCodec.encodeLiveManifest(manifest)
        XCTAssertLessThan(manifestData.count, ManifestCodec.maxLiveManifestBytes)
        XCTAssertEqual(try ManifestCodec.decodeLiveManifest(manifestData), manifest)
        let hash = ManifestCodec.liveManifestContentHash(manifestData)
        let head = LiveIngestHead(
            peer: "hq", generation: 2, seq: 7, complete: true, entryCount: 1,
            manifestKey: LiveIngestKeys.manifest(peer: "hq", generation: 2, seq: 7),
            contentHash: hash, withdrawnCount: 0
        )
        let decoded = try ManifestCodec.decodeLiveHead(ManifestCodec.encodeLiveHead(head))
        XCTAssertEqual(decoded, head)
        XCTAssertEqual(decoded.schemaVersion, LiveIngestHead.currentSchemaVersion)
    }

    func testLiveManifestRejectsOver16MiB_repro() throws {
        let oversized = Data(count: ManifestCodec.maxLiveManifestBytes + 1)
        XCTAssertThrowsError(try ManifestCodec.decodeLiveManifest(oversized)) { error in
            XCTAssertEqual(error as? RemoteSyncError, .liveManifestTooLarge)
        }
        XCTAssertThrowsError(try ManifestCodec.decodeLiveHead(oversized)) { error in
            XCTAssertEqual(error as? RemoteSyncError, .liveManifestTooLarge)
        }
    }

    func testManifestCodecRoundTrip() throws {
        let (entry, _) = makeEntryAndBundle(sessionId: "rs1", peer: "macB", hash: "ih1", fts: ["x"])
        let manifest = SyncManifest(peer: "macB", updatedAt: "2024-02-02T00:00:00Z", entries: [entry])
        let data = try ManifestCodec.encode(manifest)
        let decoded = try ManifestCodec.decode(data)
        XCTAssertEqual(decoded, manifest)
    }

    func testManifestCodecRejectsUnsupportedSchemaVersion_repro() throws {
        let (entry, _) = makeEntryAndBundle(sessionId: "rs1", peer: "macB", hash: "ih1", fts: ["x"])
        let manifest = SyncManifest(peer: "macB", updatedAt: "2024-02-02T00:00:00Z", entries: [entry])
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: ManifestCodec.encode(manifest)) as? [String: Any]
        )
        let futureVersion = SyncManifest.currentSchemaVersion + 1
        object["schemaVersion"] = futureVersion
        let data = try JSONSerialization.data(withJSONObject: object)

        XCTAssertThrowsError(try ManifestCodec.decode(data)) { error in
            XCTAssertEqual(
                error as? RemoteSyncError,
                .schemaVersionUnsupported(futureVersion)
            )
        }
    }

    func testDecodeCatalogRejectsUnsupportedEnvelopeSchemaVersion_repro() throws {
        let (entry, _) = makeEntryAndBundle(sessionId: "rs1", peer: "macB", hash: "ih1", fts: ["x"])
        let manifest = SyncManifest(peer: "macB", updatedAt: "2024-02-02T00:00:00Z", entries: [entry])
        let manifestObject = try JSONSerialization.jsonObject(with: ManifestCodec.encode(manifest))
        let catalog: [String: Any] = [
            "schemaVersion": SyncManifest.currentSchemaVersion + 1,
            "manifests": [manifestObject],
        ]
        let data = try JSONSerialization.data(withJSONObject: catalog)

        XCTAssertThrowsError(try ManifestCodec.decodeCatalog(data))
    }

    func testDecodeCatalogRejectsBooleanEnvelopeSchemaVersion_repro() throws {
        let (entry, _) = makeEntryAndBundle(sessionId: "rs1", peer: "macB", hash: "ih1", fts: ["x"])
        let manifest = SyncManifest(peer: "macB", updatedAt: "2024-02-02T00:00:00Z", entries: [entry])
        let manifestObject = try JSONSerialization.jsonObject(with: ManifestCodec.encode(manifest))
        let catalog: [String: Any] = [
            "schemaVersion": true,
            "manifests": [manifestObject],
        ]
        let data = try JSONSerialization.data(withJSONObject: catalog)

        XCTAssertThrowsError(try ManifestCodec.decodeCatalog(data))
    }

    func testDecodeCatalogSkipsUnsupportedPeerSchemaVersionButKeepsValidPeer_repro() throws {
        let (entry, _) = makeEntryAndBundle(sessionId: "rs1", peer: "macB", hash: "ih1", fts: ["x"])
        let good = SyncManifest(peer: "macB", updatedAt: "2024-02-02T00:00:00Z", entries: [entry])
        let goodObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: ManifestCodec.encode(good)) as? [String: Any]
        )
        var futureObject = goodObject
        futureObject["schemaVersion"] = SyncManifest.currentSchemaVersion + 1
        futureObject["peer"] = "future-peer"
        let catalog: [String: Any] = [
            "schemaVersion": SyncManifest.currentSchemaVersion,
            "manifests": [futureObject, goodObject],
        ]
        let data = try JSONSerialization.data(withJSONObject: catalog)

        XCTAssertEqual(
            try ManifestCodec.decodeCatalog(data),
            [good],
            "one future peer must not suppress compatible peers"
        )
    }

    func testDecodeCatalogSkipsCorruptManifests() throws {
        let (entry, _) = makeEntryAndBundle(sessionId: "rs1", peer: "macB", hash: "ih1", fts: ["x"])
        let good = SyncManifest(peer: "macB", updatedAt: "2024-02-02T00:00:00Z", entries: [entry])
        let goodObj = try JSONSerialization.jsonObject(with: ManifestCodec.encode(good))
        // Aggregated catalog with one valid + one corrupt manifest object.
        let corrupt: [String: Any] = ["peer": "macC", "garbage": true] // missing required fields
        let catalog: [String: Any] = ["schemaVersion": 1, "manifests": [goodObj, corrupt]]
        let data = try JSONSerialization.data(withJSONObject: catalog)
        let manifests = try ManifestCodec.decodeCatalog(data)
        XCTAssertEqual(manifests.count, 1, "corrupt manifest skipped, valid one survives")
        XCTAssertEqual(manifests.first, good)
    }

    func testDecodeCatalogThrowsWhenNonemptyPayloadProducesNoManifest_repro() throws {
        for object: Any in [NSNull(), 42, ["schemaVersion": 1, "manifests": [42, NSNull()]]] {
            let data = try JSONSerialization.data(withJSONObject: object, options: [.fragmentsAllowed])
            XCTAssertThrowsError(try ManifestCodec.decodeCatalog(data))
        }
        let empty = try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "manifests": []])
        XCTAssertEqual(try ManifestCodec.decodeCatalog(empty), [])
    }

    func testDecodeCatalogReturnsEmptyForSkippableLeftoverObjects_repro() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "schemaVersion": SyncManifest.currentSchemaVersion,
            "manifests": [
                ["legacy": true],
                ["schemaVersion": SyncManifest.currentSchemaVersion, "garbage": "leftover"],
            ],
        ])
        XCTAssertEqual(try ManifestCodec.decodeCatalog(data), [])
    }

    /// LocalDirectoryBackend.catalog() selects ONLY `catalog.<peer>.manifest` blobs
    /// (via ManifestCodec.isManifestKey), matching the server route's predicate: a
    /// `catalog.*` blob without the `.manifest` suffix and a malformed manifest
    /// key are both excluded here too.
    func testLocalCatalogSelectsOnlyManifestKeys() async throws {
        let dir = tempDir.appendingPathComponent("catalog-store", isDirectory: true)
        let backend = try LocalDirectoryBackend(root: dir)
        let (entry, _) = makeEntryAndBundle(sessionId: "rs1", peer: "macB", hash: "ih1", fts: ["x"])
        let manifest = SyncManifest(peer: "macB", updatedAt: "2024-02-02T00:00:00Z", entries: [entry])
        try await backend.put(key: ManifestCodec.manifestKey(peer: "macB"), data: ManifestCodec.encode(manifest))
        try await backend.put(key: "catalog.stray", data: Data("{}".utf8))         // no .manifest suffix
        try Data("{}".utf8).write(to: dir.appendingPathComponent("catalog..manifest"))
        let catalogData = try await backend.catalog()
        let manifests = try ManifestCodec.decodeCatalog(catalogData)
        XCTAssertEqual(manifests, [manifest],
                       "only catalog.<peer>.manifest blobs are aggregated; stray and malformed keys excluded")
    }

    func testLocalCatalogReturnsEmptyWhenEveryManifestObjectIsSkippable_repro() async throws {
        let dir = tempDir.appendingPathComponent("catalog-limit-store", isDirectory: true)
        let backend = try LocalDirectoryBackend(root: dir)
        let oversized = try JSONSerialization.data(withJSONObject: [
            "peer": "oversized",
            "padding": String(repeating: "x", count: 4 * 1024 * 1024),
        ])
        try await backend.put(key: "catalog.peer.manifest", data: oversized)

        let catalog = try await backend.catalog()
        XCTAssertEqual(try ManifestCodec.decodeCatalog(catalog), [])
    }

    func testLocalCatalogSkipsArrayThatExhaustsBudgetWithoutCatalogTooLarge_repro() async throws {
        let dir = tempDir.appendingPathComponent("catalog-skippable-limit-store", isDirectory: true)
        let backend = try LocalDirectoryBackend(root: dir)
        let (entry, _) = makeEntryAndBundle(
            sessionId: "valid-session",
            peer: "valid",
            hash: "valid-hash",
            fts: [String(repeating: "v", count: 1_024)]
        )
        let valid = try ManifestCodec.encode(
            SyncManifest(peer: "valid", updatedAt: "2026-08-23T00:00:00Z", entries: [entry])
        )
        let skippable = try JSONSerialization.data(withJSONObject: [
            String(repeating: "x", count: 65 * 1024 * 1024),
        ])
        XCTAssertGreaterThan(skippable.count, EngramRemoteBackend.maxBundleBytes)
        try await backend.put(key: "catalog.aaa-array.manifest", data: skippable)
        try await backend.put(key: "catalog.zzz-valid.manifest", data: valid)

        let catalog = try await backend.catalog()
        let manifests = try ManifestCodec.decodeCatalog(catalog)
        XCTAssertEqual(manifests.map(\.peer), ["valid"])
    }

    func testLocalCatalogRejectsClassifiedObjectThatExceedsRemainingBudget_repro() async throws {
        let dir = tempDir.appendingPathComponent("catalog-remaining-budget", isDirectory: true)
        let backend = try LocalDirectoryBackend(root: dir)
        let first = try JSONSerialization.data(withJSONObject: [
            "peer": "first",
            "padding": String(repeating: "a", count: 2_100_000),
        ])
        let second = try JSONSerialization.data(withJSONObject: [
            "peer": "second",
            "padding": String(repeating: "b", count: 2_100_000),
        ])
        let catalogLimit = 4 * 1_024 * 1_024
        XCTAssertLessThan(first.count, catalogLimit)
        XCTAssertLessThan(second.count, catalogLimit)
        XCTAssertGreaterThan(first.count + second.count, catalogLimit)
        try await backend.put(key: "catalog.aaa-first.manifest", data: first)
        try await backend.put(key: "catalog.bbb-second.manifest", data: second)

        do {
            _ = try await backend.catalog()
            XCTFail("a valid peer object cannot be silently omitted after the prefix consumes the budget")
        } catch let error as RemoteSyncError {
            XCTAssertEqual(error, .catalogTooLarge)
        }
    }

    func testLocalCatalogSkipsUnusableObjectsBeforeLaterValidPeer_repro() async throws {
        let (entry, _) = makeEntryAndBundle(
            sessionId: "valid-session",
            peer: "valid",
            hash: "valid-hash",
            fts: ["valid"]
        )
        let valid = try ManifestCodec.encode(
            SyncManifest(peer: "valid", updatedAt: "2026-08-23T00:00:00Z", entries: [entry])
        )

        let hugeDir = tempDir.appendingPathComponent("catalog-huge-object", isDirectory: true)
        let hugeBackend = try LocalDirectoryBackend(root: hugeDir)
        var hugeObject = Data("{\"padding\":\"".utf8)
        hugeObject.append(Data(repeating: UInt8(ascii: "x"), count: 65 * 1_024 * 1_024))
        hugeObject.append(Data("\"}".utf8))
        try await hugeBackend.put(key: "catalog.aaa-huge.manifest", data: hugeObject)
        try await hugeBackend.put(key: "catalog.zzz-valid.manifest", data: valid)
        let hugeCatalog = try await hugeBackend.catalog()
        XCTAssertEqual(
            try ManifestCodec.decodeCatalog(hugeCatalog).map(\.peer),
            ["valid"]
        )

        let overBudgetDir = tempDir.appendingPathComponent("catalog-over-budget-object", isDirectory: true)
        let overBudgetBackend = try LocalDirectoryBackend(root: overBudgetDir)
        let overBudgetObject = try JSONSerialization.data(withJSONObject: [
            "padding": String(repeating: "x", count: 5 * 1_024 * 1_024),
        ])
        try await overBudgetBackend.put(key: "catalog.aaa-over-budget.manifest", data: overBudgetObject)
        try await overBudgetBackend.put(key: "catalog.zzz-valid.manifest", data: valid)
        let overBudgetCatalog = try await overBudgetBackend.catalog()
        XCTAssertEqual(
            try ManifestCodec.decodeCatalog(overBudgetCatalog).map(\.peer),
            ["valid"]
        )

        let unreadableDir = tempDir.appendingPathComponent("catalog-unreadable-entry", isDirectory: true)
        let unreadableBackend = try LocalDirectoryBackend(root: unreadableDir)
        try FileManager.default.createDirectory(
            at: unreadableDir.appendingPathComponent("catalog.aaa-unreadable.manifest", isDirectory: true),
            withIntermediateDirectories: true
        )
        try await unreadableBackend.put(key: "catalog.zzz-valid.manifest", data: valid)
        let unreadableCatalog = try await unreadableBackend.catalog()
        XCTAssertEqual(
            try ManifestCodec.decodeCatalog(unreadableCatalog).map(\.peer),
            ["valid"]
        )
    }

    func testLocalCatalogSkipsOversizedObjectAfterValidPrefix_repro() async throws {
        let dir = tempDir.appendingPathComponent("catalog-prefix-before-oversized", isDirectory: true)
        let backend = try LocalDirectoryBackend(root: dir)
        let (entry, _) = makeEntryAndBundle(
            sessionId: "prefix-session",
            peer: "prefix",
            hash: "prefix-hash",
            fts: [String(repeating: "v", count: 1_024)]
        )
        let prefix = try ManifestCodec.encode(
            SyncManifest(peer: "prefix", updatedAt: "2026-08-24T00:00:00Z", entries: [entry])
        )
        let oversized = try JSONSerialization.data(withJSONObject: [
            "peer": "oversized",
            "padding": String(repeating: "x", count: 5 * 1_024 * 1_024),
        ])
        try await backend.put(key: "catalog.aaa-prefix.manifest", data: prefix)
        try await backend.put(key: "catalog.zzz-oversized.manifest", data: oversized)

        let catalog = try await backend.catalog()
        XCTAssertEqual(try ManifestCodec.decodeCatalog(catalog).map(\.peer), ["prefix"])
    }

    func testLocalDirectoryCatalogPropagatesDirectoryListingFailure_repro() async throws {
        let dir = tempDir.appendingPathComponent("catalog-io-failure", isDirectory: true)
        let backend = try LocalDirectoryBackend(root: dir)
        try FileManager.default.removeItem(at: dir)
        try Data("not a directory".utf8).write(to: dir)

        do {
            _ = try await backend.catalog()
            XCTFail("catalog listing I/O failures must not masquerade as an empty remote catalog")
        } catch {
            XCTAssertFalse(error is RemoteSyncError)
        }
    }
}
