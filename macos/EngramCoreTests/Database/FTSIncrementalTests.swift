import Foundation
import GRDB
import XCTest
@testable import EngramCoreRead
@testable import EngramCoreWrite

/// Coverage for the incremental FTS write path (companion `fts_map` rowid table,
/// append-only detection, self-healing delete, one-time backfill, and the FTS job
/// debounce). All temp DBs; no live DB.
final class FTSIncrementalTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("engram-fts-incremental-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        try super.tearDownWithError()
    }

    private func makeWriter(_ name: String) throws -> EngramDatabaseWriter {
        let writer = try EngramDatabaseWriter(path: tempDir.appendingPathComponent("\(name).sqlite").path)
        try writer.migrate()
        return writer
    }

    private struct MapEntry { let seq: Int; let rowid: Int64; let hash: String }

    private func readMap(_ writer: EngramDatabaseWriter, _ sessionId: String) throws -> [MapEntry] {
        try writer.read { db in
            try Row.fetchAll(
                db,
                sql: "SELECT msg_seq, fts_rowid, content_hash FROM fts_map WHERE session_id = ? ORDER BY msg_seq",
                arguments: [sessionId]
            ).map { MapEntry(seq: $0["msg_seq"], rowid: $0["fts_rowid"], hash: $0["content_hash"] ?? "") }
        }
    }

    private func content(_ writer: EngramDatabaseWriter, _ sessionId: String) throws -> [String] {
        try writer.read { db in
            try String.fetchAll(
                db,
                sql: "SELECT content FROM sessions_fts WHERE session_id = ? ORDER BY content",
                arguments: [sessionId]
            )
        }
    }

    // MARK: - Search parity: N incremental appends == one from-scratch rebuild

    func testIncrementalAppendsMatchFullRebuild() throws {
        let writer = try makeWriter("parity")
        let messages = (1...6).map { "message number \($0) about topicword\($0)" }
        let summaryEarly = "early summary alpha"
        let summaryFinal = "final summary omega"

        // Incrementally: grow the message list and change the summary.
        try writer.write { db in
            try FTSRebuildPolicy.replaceFtsContent(db, sessionId: "inc", messages: Array(messages[0..<2]), summary: summaryEarly)
        }
        try writer.write { db in
            try FTSRebuildPolicy.replaceFtsContent(db, sessionId: "inc", messages: Array(messages[0..<4]), summary: summaryEarly)
        }
        try writer.write { db in
            try FTSRebuildPolicy.replaceFtsContent(db, sessionId: "inc", messages: messages, summary: summaryFinal)
        }
        // From scratch: a fresh session indexed once with the final content.
        try writer.write { db in
            try FTSRebuildPolicy.replaceFtsContent(db, sessionId: "full", messages: messages, summary: summaryFinal)
        }

        XCTAssertEqual(try content(writer, "inc"), try content(writer, "full"))
        XCTAssertEqual(Set(try content(writer, "inc")), Set(messages + [summaryFinal]))

        // MATCH parity: the appended tail and the current summary are searchable on
        // both sessions; the replaced summary is not.
        let tailHits = try writer.read { db in
            try String.fetchAll(
                db,
                sql: "SELECT DISTINCT session_id FROM sessions_fts WHERE sessions_fts MATCH ? ORDER BY session_id",
                arguments: ["topicword6"]
            )
        }
        XCTAssertEqual(tailHits, ["full", "inc"])
        let staleSummaryHits = try writer.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM sessions_fts WHERE session_id = 'inc' AND sessions_fts MATCH ?",
                arguments: ["alpha"]
            )
        }
        XCTAssertEqual(staleSummaryHits, 0, "replaced summary must not remain searchable")

        // Map: 6 message rows (0..5) + one summary row (-1), all with real hashes.
        let map = try readMap(writer, "inc")
        XCTAssertEqual(map.map(\.seq), [-1, 0, 1, 2, 3, 4, 5])
        XCTAssertFalse(map.contains { $0.hash.isEmpty })
    }

    // MARK: - Append keeps prefix rows in place (the core optimization)

    func testAppendOnlyKeepsPrefixRowids() throws {
        let writer = try makeWriter("append")
        try writer.write { db in
            try FTSRebuildPolicy.replaceFtsContent(db, sessionId: "s1", messages: ["one apple", "two banana"], summary: "stable summary")
        }
        let before = try readMap(writer, "s1")
        try writer.write { db in
            try FTSRebuildPolicy.replaceFtsContent(db, sessionId: "s1", messages: ["one apple", "two banana", "three cherry"], summary: "stable summary")
        }
        let after = try readMap(writer, "s1")

        let beforeMsgs = before.filter { $0.seq >= 0 }
        let afterMsgs = after.filter { $0.seq >= 0 }
        XCTAssertEqual(afterMsgs.count, 3)
        // Existing message rows were NOT deleted+reinserted: their rowids are stable.
        XCTAssertEqual(beforeMsgs[0].rowid, afterMsgs[0].rowid)
        XCTAssertEqual(beforeMsgs[1].rowid, afterMsgs[1].rowid)
        // Unchanged summary keeps its row too.
        XCTAssertEqual(before.first { $0.seq == -1 }?.rowid, after.first { $0.seq == -1 }?.rowid)
        XCTAssertEqual(try content(writer, "s1"), ["one apple", "stable summary", "three cherry", "two banana"])
    }

    // MARK: - Prefix rewrite falls back to a full replace

    func testPrefixRewriteFallsBackToFullReplace() throws {
        let writer = try makeWriter("rewrite")
        try writer.write { db in
            try FTSRebuildPolicy.replaceFtsContent(db, sessionId: "s1", messages: ["alpha line", "beta line", "gamma line"], summary: nil)
        }

        // Message 0 rewritten (prefix changed) + grew: must full-replace, not append.
        try writer.write { db in
            try FTSRebuildPolicy.replaceFtsContent(db, sessionId: "s1", messages: ["ALPHA rewritten", "beta line", "gamma line", "delta line"], summary: nil)
        }

        // Exactly the new content — a wrong append would have LEFT "alpha line" behind
        // and produced 5 rows, so this equality alone proves the full-replace fallback.
        XCTAssertEqual(try content(writer, "s1"), ["ALPHA rewritten", "beta line", "delta line", "gamma line"])
        let staleHits = try writer.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sessions_fts WHERE session_id = 's1' AND content = 'alpha line'") ?? -1
        }
        XCTAssertEqual(staleHits, 0, "rewritten prefix must not remain searchable")
        let map = try readMap(writer, "s1").filter { $0.seq >= 0 }
        XCTAssertEqual(map.map(\.seq), [0, 1, 2, 3], "map rebuilt to the new message set")
    }

    // MARK: - No-map fallback + external-delete self-heal

    func testNoMapFallbackAndSelfHealOnExternalDelete() throws {
        let writer = try makeWriter("selfheal")
        // Pre-backfill rows: FTS rows exist with NO map entries.
        try writer.write { db in
            try db.execute(sql: "INSERT INTO sessions_fts(session_id, content) VALUES ('s1', 'stale one'), ('s1', 'stale two')")
        }
        try writer.write { db in
            try FTSRebuildPolicy.replaceFtsContent(db, sessionId: "s1", messages: ["fresh one", "fresh two"], summary: nil)
        }
        XCTAssertEqual(try content(writer, "s1"), ["fresh one", "fresh two"], "no-map scan fallback heals pre-backfill rows")

        // External delete (e.g. skip-tier reconcile) removes FTS rows but leaves stale
        // map rows behind. The next write must not leave missing content.
        try writer.write { db in
            try db.execute(sql: "DELETE FROM sessions_fts WHERE session_id = 's1'")
        }
        XCTAssertGreaterThan(try readMap(writer, "s1").count, 0, "map rows are stale after external FTS delete")
        try writer.write { db in
            try FTSRebuildPolicy.replaceFtsContent(db, sessionId: "s1", messages: ["healed one", "healed two", "healed three"], summary: nil)
        }
        XCTAssertEqual(try content(writer, "s1"), ["healed one", "healed three", "healed two"])
        let (mapCount, ftsCount) = try writer.read { db in
            (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM fts_map WHERE session_id = 's1'") ?? -1,
             try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sessions_fts WHERE session_id = 's1'") ?? -2)
        }
        XCTAssertEqual(mapCount, ftsCount)
        XCTAssertEqual(ftsCount, 3)
    }

    // MARK: - Rowid-seek delete never touches another session's rows

    func testFullReplaceGuardsAgainstReusedRowid() throws {
        let writer = try makeWriter("crossguard")
        try writer.write { db in
            try FTSRebuildPolicy.replaceFtsContent(db, sessionId: "s2", messages: ["keep me safe"], summary: nil)
        }
        let s2Rowid = try writer.read { db in
            try Int64.fetchOne(db, sql: "SELECT fts_rowid FROM fts_map WHERE session_id = 's2' AND msg_seq = 0") ?? -1
        }
        // Craft a stale s1 map row pointing at s2's rowid (simulates rowid reuse after
        // an external delete / table swap). content_hash != real → not append-only.
        try writer.write { db in
            try db.execute(
                sql: "INSERT INTO fts_map(session_id, msg_seq, fts_rowid, content_hash) VALUES ('s1', 0, ?, 'deadbeefdeadbeef')",
                arguments: [s2Rowid]
            )
        }
        try writer.write { db in
            try FTSRebuildPolicy.replaceFtsContent(db, sessionId: "s1", messages: ["s1 new content"], summary: nil)
        }
        let s2Survives = try writer.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sessions_fts WHERE session_id = 's2' AND content = 'keep me safe'") ?? -1
        }
        XCTAssertEqual(s2Survives, 1, "session_id-guarded rowid delete must not remove another session's row")
        XCTAssertEqual(try content(writer, "s1"), ["s1 new content"])
    }

    // MARK: - Reused rowid + unchanged content must not mask missing FTS rows

    /// The self-heal guard must verify rowid *ownership*, not mere existence. When a
    /// skip-tier delete frees a session's FTS rowids, leaves its `fts_map` behind, and an
    /// unrelated insert reuses those exact rowids, an unchanged re-index of the original
    /// session hits both the append-only fast path (content unchanged → nothing to append)
    /// and a bare rowid-existence check (reused rowids look "present"). Without the
    /// `session_id` ownership filter this leaves the session with zero real FTS rows and
    /// silently unsearchable forever.
    func testReusedRowidWithUnchangedContentIsNotMaskedByStaleMap() throws {
        let writer = try makeWriter("ownership")
        let messages = ["alpha ownershipword", "beta ownershipword"]
        try writer.write { db in
            try FTSRebuildPolicy.replaceFtsContent(db, sessionId: "s1", messages: messages, summary: nil)
        }
        let rowids = try readMap(writer, "s1").filter { $0.seq >= 0 }.map(\.rowid)
        XCTAssertEqual(rowids.count, 2)

        // Skip-tier delete frees s1's FTS rows but leaks its map rows.
        try writer.write { db in
            try db.execute(sql: "DELETE FROM sessions_fts WHERE session_id = 's1'")
        }
        // An unrelated session reuses s1's exact freed rowids.
        try writer.write { db in
            for rowid in rowids {
                try db.execute(
                    sql: "INSERT INTO sessions_fts(rowid, session_id, content) VALUES (?, 's2', 'decoy row')",
                    arguments: [rowid]
                )
            }
        }
        // Re-index s1 with UNCHANGED content: append-only + reused-rowid count both look
        // consistent, so only an ownership-aware guard falls back to a full replace.
        try writer.write { db in
            try FTSRebuildPolicy.replaceFtsContent(db, sessionId: "s1", messages: messages, summary: nil)
        }

        XCTAssertEqual(try content(writer, "s1"), messages, "s1 content must survive a reused-rowid stale map")
        let s1Hits = try writer.read { db in
            try String.fetchAll(
                db,
                sql: "SELECT DISTINCT session_id FROM sessions_fts WHERE sessions_fts MATCH ? ORDER BY session_id",
                arguments: ["ownershipword"]
            )
        }
        XCTAssertEqual(s1Hits, ["s1"], "s1 must be searchable again after the full-replace fallback")
        let s2Survives = try writer.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sessions_fts WHERE session_id = 's2' AND content = 'decoy row'") ?? -1
        }
        XCTAssertEqual(s2Survives, rowids.count, "the ownership-guarded replace must not touch the reusing session's rows")
    }

    // MARK: - Migration idempotency + one-time backfill from existing FTS rows

    func testMigrationBackfillsMapAndIsIdempotent() throws {
        let writer = try makeWriter("migrate")
        // Seed FTS rows then force the backfill to re-run (first migrate ran it on an
        // empty table).
        try writer.write { db in
            try db.execute(sql: """
                INSERT INTO sessions_fts(session_id, content)
                VALUES ('s1', 'row a'), ('s1', 'row b'), ('s2', 'row c')
            """)
            try db.execute(sql: "DELETE FROM metadata WHERE key = ?", arguments: [FTSRebuildPolicy.mapBackfillKey])
        }
        try writer.migrate()

        XCTAssertEqual(try writer.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM fts_map") }, 3)
        let s1Seqs = try writer.read { db in
            try Int.fetchAll(db, sql: "SELECT msg_seq FROM fts_map WHERE session_id = 's1' ORDER BY msg_seq")
        }
        XCTAssertEqual(s1Seqs, [0, 1], "backfill numbers each session's rows from 0 in rowid order")
        XCTAssertEqual(
            try writer.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM fts_map WHERE content_hash = ''") },
            3,
            "backfill leaves sentinel hashes so the first re-index does a clean full replace"
        )

        // Running migrate again (flag now set) must not duplicate or drop rows.
        try writer.migrate()
        XCTAssertEqual(try writer.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM fts_map") }, 3)

        // A backfilled (sentinel) session re-indexes to a clean incremental state.
        try writer.write { db in
            try FTSRebuildPolicy.replaceFtsContent(db, sessionId: "s1", messages: ["row a", "row b", "row c"], summary: nil)
        }
        let s1Map = try readMap(writer, "s1")
        XCTAssertEqual(s1Map.map(\.seq), [0, 1, 2])
        XCTAssertFalse(s1Map.contains { $0.hash.isEmpty }, "sentinel hashes replaced with real ones after re-index")
    }

    // MARK: - Debounce: defer a hot session but honor the max-delay bound

    private func normalSnapshot(id: String, syncVersion: Int, hash: String) -> AuthoritativeSessionSnapshot {
        AuthoritativeSessionSnapshot(
            id: id,
            source: .claudeCode,
            authoritativeNode: "node-a",
            syncVersion: syncVersion,
            snapshotHash: hash,
            indexedAt: "2026-03-18T12:00:00Z",
            sourceLocator: "/tmp/\(id).jsonl",
            sizeBytes: 128,
            startTime: "2026-03-18T11:00:00Z",
            endTime: nil,
            cwd: "/repo",
            project: "demo",
            model: "claude",
            messageCount: 2,
            userMessageCount: 1,
            assistantMessageCount: 1,
            toolMessageCount: 0,
            systemMessageCount: 0,
            summary: "summary \(hash)",
            summaryMessageCount: nil,
            origin: nil,
            tier: .normal,
            agentRole: nil,
            toolCallCounts: [:]
        )
    }

    func testFtsJobDebounceDefersHotSessionButHonorsMaxDelay() throws {
        let writer = try makeWriter("debounce")

        // First enqueue: no backlog → not_before is NULL (indexed immediately).
        try writer.write { db in
            _ = try SessionBatchUpsert(db: db).upsertBatch([normalSnapshot(id: "hot", syncVersion: 1, hash: "h1")], reason: .initialScan)
        }
        XCTAssertNil(
            try writer.read { db in try String.fetchOne(db, sql: "SELECT not_before FROM session_index_jobs WHERE session_id = 'hot' AND job_kind = 'fts'") },
            "a first enqueue must not be deferred"
        )

        // Re-enqueue while the first job is still pending → the coalesced job is
        // deferred into the future.
        try writer.write { db in
            _ = try SessionBatchUpsert(db: db).upsertBatch([normalSnapshot(id: "hot", syncVersion: 2, hash: "h2")], reason: .initialScan)
        }
        let (pending, deferred) = try writer.read { db -> (Int, Bool) in
            let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM session_index_jobs WHERE session_id = 'hot' AND job_kind = 'fts' AND status = 'pending'") ?? -1
            let future = try Bool.fetchOne(db, sql: """
                SELECT EXISTS(
                  SELECT 1 FROM session_index_jobs
                  WHERE session_id = 'hot' AND job_kind = 'fts' AND status = 'pending'
                    AND not_before IS NOT NULL AND not_before > datetime('now')
                )
            """) ?? false
            return (count, future)
        }
        XCTAssertEqual(pending, 1, "rapid appends coalesce into a single pending FTS job")
        XCTAssertTrue(deferred, "an actively-appending session's FTS job is deferred")

        // Max-delay bound: pin the first enqueue far in the past, re-enqueue, and the
        // clamp puts not_before in the past → the job is claimable again.
        try writer.write { db in
            try db.execute(sql: "UPDATE session_index_jobs SET created_at = '2000-01-01 00:00:00' WHERE session_id = 'hot' AND job_kind = 'fts' AND status = 'pending'")
        }
        try writer.write { db in
            _ = try SessionBatchUpsert(db: db).upsertBatch([normalSnapshot(id: "hot", syncVersion: 3, hash: "h3")], reason: .initialScan)
        }
        let claimableAfterMaxDelay = try writer.read { db in
            try Bool.fetchOne(db, sql: """
                SELECT EXISTS(
                  SELECT 1 FROM session_index_jobs
                  WHERE session_id = 'hot' AND job_kind = 'fts' AND status = 'pending'
                    AND (not_before IS NULL OR not_before <= datetime('now'))
                )
            """) ?? false
        }
        XCTAssertTrue(claimableAfterMaxDelay, "content must be searchable within the max-delay bound of the first enqueue")
    }
}
