import CryptoKit
import Foundation
import GRDB

public enum FTSRebuildPolicy {
    public static let expectedVersion = "3"
    private static let rebuildVersionKey = "fts_rebuild_version"
    private static let activeTable = "sessions_fts"
    private static let rebuildTable = "sessions_fts_rebuild"

    /// `fts_map` companion (ordinary, indexed) row for the session summary. Kept
    /// out of the append-stable message range (`msg_seq >= 0`) because the summary
    /// is written last and can change independently of the transcript, so tracking
    /// it separately lets message appends stay incremental.
    private static let summaryMsgSeq = -1
    static let mapBackfillKey = "fts_map_backfilled"

    public static func apply(_ db: GRDB.Database) throws {
        let current = try String.fetchOne(
            db,
            sql: "SELECT value FROM metadata WHERE key = 'fts_version'"
        )
        guard current != expectedVersion else { return }

        if current == nil, try sessionCount(db) == 0 {
            try db.execute(sql: "DROP TABLE IF EXISTS \(rebuildTable)")
            try markCurrentVersion(db)
            try db.execute(sql: "DELETE FROM metadata WHERE key = ?", arguments: [rebuildVersionKey])
            return
        }

        let pending = try String.fetchOne(
            db,
            sql: "SELECT value FROM metadata WHERE key = ?",
            arguments: [rebuildVersionKey]
        )
        let rebuildTableMissing = try !tableExists(db, rebuildTable)
        let startedRebuild = pending != expectedVersion || rebuildTableMissing
        if startedRebuild {
            try db.execute(sql: "DROP TABLE IF EXISTS \(rebuildTable)")
            try createFtsTable(db, named: rebuildTable)
        }
        if try tableExists(db, "session_embeddings") {
            try db.execute(sql: "DELETE FROM session_embeddings")
        }
        if try tableExists(db, "vec_sessions") {
            try db.execute(sql: "DELETE FROM vec_sessions")
        }
        try db.execute(
            sql: """
            INSERT INTO metadata(key, value) VALUES (?, ?)
            ON CONFLICT(key) DO UPDATE SET value = excluded.value
            """,
            arguments: [rebuildVersionKey, expectedVersion]
        )
        // Keep the live FTS table serving search while the runner builds the
        // replacement table. Re-open the already-completed FTS jobs so unchanged
        // sessions are replayed into `sessions_fts_rebuild`.
        if startedRebuild, try tableExists(db, "session_index_jobs") {
            try db.execute(sql: """
                UPDATE session_index_jobs
                SET status = 'pending', retry_count = 0, last_error = NULL,
                    updated_at = datetime('now')
                WHERE job_kind = 'fts' AND status = 'completed'
            """)
        }
    }

    /// Back-compat entry: callers that already hold a flat content list (offload
    /// shadow, bundle rehydrate) pass it as append-stable messages with no separate
    /// summary. Search rows are identical to the old behaviour.
    static func replaceFtsContent(_ db: GRDB.Database, sessionId: String, contents: [String]) throws {
        try replaceFtsContent(db, sessionId: sessionId, messages: contents, summary: nil)
    }

    /// Incremental FTS write. The live `sessions_fts` table is updated through the
    /// `fts_map` rowid companion so a delete seeks by rowid instead of full-scanning
    /// the UNINDEXED `session_id`, and appends only tokenize the new tail. Any doubt
    /// about append-only-ness (prefix rewrite, backfill sentinel, externally deleted
    /// rows) falls back to a full per-session replace, so a stale/missing map can
    /// never corrupt search results.
    static func replaceFtsContent(
        _ db: GRDB.Database,
        sessionId: String,
        messages: [String],
        summary: String?
    ) throws {
        try replaceActiveFtsContent(db, sessionId: sessionId, messages: messages, summary: summary)
        if try rebuildIsPending(db) {
            // The shadow rebuild table has no rowid map; keep the old full
            // delete+insert of the combined content so the table swap yields correct
            // search rows. `finalizeRebuildIfReady` rebuilds the map afterwards.
            var combined = messages
            if let summaryLine = normalizedSummary(summary) {
                combined.append(summaryLine)
            }
            try replaceFtsContentFull(db, table: rebuildTable, sessionId: sessionId, contents: combined)
        }
    }

    @discardableResult
    static func finalizeRebuildIfReady(_ db: GRDB.Database) throws -> Bool {
        guard try rebuildIsPending(db) else { return false }
        guard try tableExists(db, rebuildTable) else { return false }
        guard try recoverableFtsJobCount(db) == 0 else { return false }

        // Wave 7A H01: before swap, copy live FTS rows for eligible sessions that
        // never made it into the shadow table (failed_permanent / not_applicable /
        // never-replayed). Permanent job failures must not delete searchable content.
        try copyMissingLiveFtsRowsIntoRebuild(db)
        guard try eligibleSessionsMissingRebuildContent(db) == 0 else {
            // Still incomplete — keep live table serving search; leave rebuild pending.
            return false
        }

        if try tableExists(db, activeTable) {
            try db.execute(sql: "DROP TABLE IF EXISTS sessions_fts_old")
            try db.execute(sql: "ALTER TABLE \(activeTable) RENAME TO sessions_fts_old")
        }
        try db.execute(sql: "ALTER TABLE \(rebuildTable) RENAME TO \(activeTable)")
        try db.execute(sql: "DROP TABLE IF EXISTS sessions_fts_old")
        try markCurrentVersion(db)
        try db.execute(sql: "DELETE FROM metadata WHERE key = ?", arguments: [rebuildVersionKey])
        try db.execute(sql: "DELETE FROM metadata WHERE key = ?", arguments: [StartupBackfills.ftsOptimizeSignatureKey])
        // The swapped-in table has fresh rowids, so the map built against the old
        // active table is stale. Rebuild it from the new table (sentinel hashes force
        // one full per-session replace on the next re-index, which restores hashes).
        try backfillFtsMap(db)
        return true
    }

    /// Eligible = non-skip, non-deleted/orphan sessions that currently have live
    /// FTS content. Skip-tier and purged sessions are intentionally omitted.
    private static func eligibleSessionSQLPredicate(alias: String = "s") -> String {
        """
        COALESCE(\(alias).tier, 'normal') != 'skip'
        AND \(alias).hidden_at IS NULL
        AND \(alias).orphan_status IS NULL
        """
    }

    private static func copyMissingLiveFtsRowsIntoRebuild(_ db: GRDB.Database) throws {
        guard try tableExists(db, activeTable), try tableExists(db, rebuildTable) else { return }
        guard try tableExists(db, "sessions") else { return }
        try db.execute(sql: """
            INSERT INTO \(rebuildTable)(session_id, content)
            SELECT live.session_id, live.content
            FROM \(activeTable) AS live
            INNER JOIN sessions AS s ON s.id = live.session_id
            WHERE \(eligibleSessionSQLPredicate())
              AND NOT EXISTS (
                SELECT 1 FROM \(rebuildTable) AS shadow
                WHERE shadow.session_id = live.session_id
              )
            """)
    }

    private static func eligibleSessionsMissingRebuildContent(_ db: GRDB.Database) throws -> Int {
        guard try tableExists(db, "sessions") else { return 0 }
        // Only require shadow content for sessions that already had live rows —
        // brand-new sessions without any FTS yet should not block finalize.
        guard try tableExists(db, activeTable) else { return 0 }
        return try Int.fetchOne(
            db,
            sql: """
            SELECT COUNT(*)
            FROM sessions AS s
            WHERE \(eligibleSessionSQLPredicate())
              AND EXISTS (
                SELECT 1 FROM \(activeTable) AS live
                WHERE live.session_id = s.id
              )
              AND NOT EXISTS (
                SELECT 1 FROM \(rebuildTable) AS shadow
                WHERE shadow.session_id = s.id
              )
            """
        ) ?? 0
    }

    /// Populate `fts_map` from the current `sessions_fts` rows in one cheap scan (no
    /// re-tokenization). Idempotent and resumable: it clears the map first, so a
    /// crashed run simply re-runs. `content_hash` is left as a sentinel so the first
    /// per-session re-index does a full replace and records real hashes.
    static func backfillFtsMap(_ db: GRDB.Database) throws {
        guard try tableExists(db, "fts_map") else { return }
        try db.execute(sql: "DELETE FROM fts_map")
        try db.execute(sql: """
            INSERT INTO fts_map(session_id, msg_seq, fts_rowid, content_hash)
            SELECT session_id,
                   ROW_NUMBER() OVER (PARTITION BY session_id ORDER BY rowid) - 1,
                   rowid,
                   ''
            FROM \(activeTable)
            WHERE session_id IS NOT NULL
        """)
    }

    // MARK: - Active-table incremental write

    private struct FtsMapRow {
        let msgSeq: Int
        let rowid: Int64
        let hash: String
    }

    private static func replaceActiveFtsContent(
        _ db: GRDB.Database,
        sessionId: String,
        messages: [String],
        summary: String?
    ) throws {
        let msgs = messages.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let summaryLine = normalizedSummary(summary)
        let existing = try fetchMapRows(db, sessionId: sessionId)

        if existing.isEmpty {
            // No map rows: heal any pre-backfill FTS rows with a single session_id
            // scan (this is the only path that scans, and it runs at most once per
            // session — brand-new sessions have nothing to delete), then insert fresh.
            try db.execute(
                sql: "DELETE FROM \(activeTable) WHERE session_id = ?",
                arguments: [sessionId]
            )
            try insertFresh(db, sessionId: sessionId, messages: msgs, summary: summaryLine)
            return
        }

        let messageRows = existing.filter { $0.msgSeq >= 0 }
        let summaryRow = existing.first { $0.msgSeq == summaryMsgSeq }
        let indexedCount = messageRows.count

        // Self-heal guard: every mapped rowid must still be present in the FTS table
        // AND still belong to this session. The `session_id` filter is essential: after
        // an external delete (e.g. the skip-tier reconcile) frees this session's rowids,
        // an unrelated FTS insert can reuse them, so a bare rowid-existence check would
        // count another session's row as ours and wrongly take the fast/append-only path,
        // permanently masking our missing content. A mismatch here forces a full replace.
        let mappedFtsCount = try Int.fetchOne(
            db,
            sql: "SELECT COUNT(*) FROM \(activeTable) WHERE session_id = ? AND rowid IN (SELECT fts_rowid FROM fts_map WHERE session_id = ?)",
            arguments: [sessionId, sessionId]
        ) ?? 0
        let mapConsistent = mappedFtsCount == existing.count

        if mapConsistent, isAppendOnly(messageRows: messageRows, messages: msgs) {
            for i in indexedCount..<msgs.count {
                let rowid = try insertFtsRow(db, sessionId: sessionId, content: msgs[i])
                try insertMapRow(db, sessionId: sessionId, msgSeq: i, rowid: rowid, hash: contentHash(msgs[i]))
            }
            try reconcileSummary(db, sessionId: sessionId, summaryRow: summaryRow, summary: summaryLine)
            return
        }

        // Full replace. Prefer the rowid-seek delete (no full-table scan); the
        // `session_id` filter guards against stale/reused rowids after a table swap.
        // If the map diverged from the FTS table, heal with one session_id scan.
        if mapConsistent {
            try db.execute(
                sql: """
                DELETE FROM \(activeTable)
                WHERE rowid IN (SELECT fts_rowid FROM fts_map WHERE session_id = ?)
                  AND session_id = ?
                """,
                arguments: [sessionId, sessionId]
            )
        } else {
            try db.execute(
                sql: "DELETE FROM \(activeTable) WHERE session_id = ?",
                arguments: [sessionId]
            )
        }
        try db.execute(sql: "DELETE FROM fts_map WHERE session_id = ?", arguments: [sessionId])
        try insertFresh(db, sessionId: sessionId, messages: msgs, summary: summaryLine)
    }

    /// True when the stored message rows are exactly the prefix of the new message
    /// list (same order, same content) and the list only grew. Backfill sentinels
    /// (`content_hash = ''`) and any prefix rewrite return false → full replace.
    private static func isAppendOnly(messageRows: [FtsMapRow], messages: [String]) -> Bool {
        let k = messageRows.count
        guard k > 0, messages.count >= k else { return false }
        for i in 0..<k {
            let row = messageRows[i]
            guard row.msgSeq == i, !row.hash.isEmpty, row.hash == contentHash(messages[i]) else {
                return false
            }
        }
        return true
    }

    private static func reconcileSummary(
        _ db: GRDB.Database,
        sessionId: String,
        summaryRow: FtsMapRow?,
        summary: String?
    ) throws {
        switch (summaryRow, summary) {
        case (nil, nil):
            break
        case let (nil, .some(line)):
            let rowid = try insertFtsRow(db, sessionId: sessionId, content: line)
            try insertMapRow(db, sessionId: sessionId, msgSeq: summaryMsgSeq, rowid: rowid, hash: contentHash(line))
        case let (.some(row), nil):
            try deleteSummaryRow(db, sessionId: sessionId, rowid: row.rowid)
        case let (.some(row), .some(line)):
            guard row.hash != contentHash(line) else { break }
            try deleteSummaryRow(db, sessionId: sessionId, rowid: row.rowid)
            let rowid = try insertFtsRow(db, sessionId: sessionId, content: line)
            try insertMapRow(db, sessionId: sessionId, msgSeq: summaryMsgSeq, rowid: rowid, hash: contentHash(line))
        }
    }

    private static func deleteSummaryRow(_ db: GRDB.Database, sessionId: String, rowid: Int64) throws {
        try db.execute(
            sql: "DELETE FROM \(activeTable) WHERE rowid = ? AND session_id = ?",
            arguments: [rowid, sessionId]
        )
        try db.execute(
            sql: "DELETE FROM fts_map WHERE session_id = ? AND msg_seq = ?",
            arguments: [sessionId, summaryMsgSeq]
        )
    }

    private static func insertFresh(
        _ db: GRDB.Database,
        sessionId: String,
        messages: [String],
        summary: String?
    ) throws {
        for (i, content) in messages.enumerated() {
            let rowid = try insertFtsRow(db, sessionId: sessionId, content: content)
            try insertMapRow(db, sessionId: sessionId, msgSeq: i, rowid: rowid, hash: contentHash(content))
        }
        if let summary {
            let rowid = try insertFtsRow(db, sessionId: sessionId, content: summary)
            try insertMapRow(db, sessionId: sessionId, msgSeq: summaryMsgSeq, rowid: rowid, hash: contentHash(summary))
        }
    }

    private static func insertFtsRow(_ db: GRDB.Database, sessionId: String, content: String) throws -> Int64 {
        try db.execute(
            sql: "INSERT INTO \(activeTable)(session_id, content) VALUES (?, ?)",
            arguments: [sessionId, content]
        )
        return db.lastInsertedRowID
    }

    private static func insertMapRow(
        _ db: GRDB.Database,
        sessionId: String,
        msgSeq: Int,
        rowid: Int64,
        hash: String
    ) throws {
        try db.execute(
            sql: "INSERT INTO fts_map(session_id, msg_seq, fts_rowid, content_hash) VALUES (?, ?, ?, ?)",
            arguments: [sessionId, msgSeq, rowid, hash]
        )
    }

    private static func fetchMapRows(_ db: GRDB.Database, sessionId: String) throws -> [FtsMapRow] {
        guard try tableExists(db, "fts_map") else { return [] }
        return try Row.fetchAll(
            db,
            sql: "SELECT msg_seq, fts_rowid, content_hash FROM fts_map WHERE session_id = ? ORDER BY msg_seq",
            arguments: [sessionId]
        ).map { row in
            FtsMapRow(msgSeq: row["msg_seq"], rowid: row["fts_rowid"], hash: row["content_hash"] ?? "")
        }
    }

    private static func normalizedSummary(_ summary: String?) -> String? {
        guard let summary, !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return summary
    }

    /// Deterministic 128-bit content hash (first 16 bytes of SHA-256). Used only to
    /// detect prefix changes; never `hashValue` (non-deterministic across runs).
    private static func contentHash(_ content: String) -> String {
        SHA256.hash(data: Data(content.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    private static func markCurrentVersion(_ db: GRDB.Database) throws {
        try db.execute(
            sql: """
            INSERT INTO metadata(key, value) VALUES ('fts_version', ?)
            ON CONFLICT(key) DO UPDATE SET value = excluded.value
            """,
            arguments: [expectedVersion]
        )
    }

    private static func createFtsTable(_ db: GRDB.Database, named table: String) throws {
        try db.execute(sql: """
            CREATE VIRTUAL TABLE \(table) USING fts5(
              session_id UNINDEXED,
              content,
              tokenize='trigram case_sensitive 0'
            )
        """)
    }

    /// Full delete-then-insert used for the shadow rebuild table only (it has no
    /// rowid map). This is the legacy `replaceFtsContent` behaviour.
    private static func replaceFtsContentFull(
        _ db: GRDB.Database,
        table: String,
        sessionId: String,
        contents: [String]
    ) throws {
        try db.execute(sql: "DELETE FROM \(table) WHERE session_id = ?", arguments: [sessionId])
        for content in contents {
            guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            try db.execute(
                sql: "INSERT INTO \(table)(session_id, content) VALUES (?, ?)",
                arguments: [sessionId, content]
            )
        }
    }

    private static func rebuildIsPending(_ db: GRDB.Database) throws -> Bool {
        try String.fetchOne(
            db,
            sql: "SELECT value FROM metadata WHERE key = ?",
            arguments: [rebuildVersionKey]
        ) == expectedVersion
    }

    private static func recoverableFtsJobCount(_ db: GRDB.Database) throws -> Int {
        guard try tableExists(db, "session_index_jobs") else { return 0 }
        return try Int.fetchOne(
            db,
            sql: """
            SELECT COUNT(*)
            FROM session_index_jobs
            WHERE job_kind = 'fts' AND status IN ('pending', 'failed_retryable')
            """
        ) ?? 0
    }

    private static func sessionCount(_ db: GRDB.Database) throws -> Int {
        guard try tableExists(db, "sessions") else { return 0 }
        return try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sessions") ?? 0
    }

    private static func tableExists(_ db: GRDB.Database, _ table: String) throws -> Bool {
        try String.fetchOne(
            db,
            sql: "SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?",
            arguments: [table]
        ) != nil
    }
}
