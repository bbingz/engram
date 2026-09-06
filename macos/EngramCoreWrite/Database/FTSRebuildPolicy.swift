import CryptoKit
import Foundation
import GRDB
import EngramCoreRead

/// Explicit capture authority supplied by a future service-owned caller.
public struct CaptureFTSReadinessPolicy: Sendable {
    public let parserRevision: String
    public let enabledSources: Set<SourceName>
    public let deadline: ContinuousClock.Instant?

    public init(parserRevision: String, enabledSources: Set<SourceName>, deadline: ContinuousClock.Instant? = nil) {
        self.parserRevision = parserRevision
        self.enabledSources = enabledSources
        self.deadline = deadline
    }
}

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
                  AND EXISTS (
                    SELECT 1 FROM sessions s
                    WHERE s.id = session_index_jobs.session_id
                      AND COALESCE(s.tier, 'normal') != 'skip'
                  )
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
        // docs/invariants.md #3 and #5: skip rows stay absent from both the
        // live corpus and a pending versioned rebuild shadow.
        if try sessionIsSkip(db, sessionId: sessionId) {
            try purgeFtsContent(db, sessionId: sessionId)
            return
        }
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
    static func finalizeRebuildIfReady(
        _ db: GRDB.Database,
        enabledSources: Set<SourceName>? = nil,
        capturePolicy: CaptureFTSReadinessPolicy? = nil
    ) throws -> Bool {
        guard try rebuildIsPending(db) else { return false }
        guard try tableExists(db, rebuildTable) else { return false }
        guard try recoverableFtsJobCount(db, enabledSources: enabledSources, capturePolicy: capturePolicy) == 0 else { return false }

        // Wave 7A H01: before swap, copy live FTS rows for eligible sessions that
        // never made it into the shadow table (failed_permanent / not_applicable /
        // never-replayed). Permanent job failures must not delete searchable content.
        try copyMissingLiveFtsRowsIntoRebuild(db)
        // Only skip is stripped here. Hidden/orphan rows intentionally retain
        // shadow content so unhide/recovery does not require a full reindex.
        try db.execute(sql: """
            DELETE FROM \(rebuildTable)
            WHERE session_id IN (
              SELECT id FROM sessions WHERE COALESCE(tier, 'normal') = 'skip'
            )
            """)
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

    static func purgeFtsContent(_ db: GRDB.Database, sessionId: String) throws {
        if try tableExists(db, activeTable) {
            try db.execute(sql: "DELETE FROM \(activeTable) WHERE session_id = ?", arguments: [sessionId])
        }
        if try tableExists(db, rebuildTable) {
            try db.execute(sql: "DELETE FROM \(rebuildTable) WHERE session_id = ?", arguments: [sessionId])
        }
        if try tableExists(db, "fts_map") {
            try db.execute(sql: "DELETE FROM fts_map WHERE session_id = ?", arguments: [sessionId])
        }
    }

    private static func sessionIsSkip(_ db: GRDB.Database, sessionId: String) throws -> Bool {
        try String.fetchOne(
            db,
            sql: "SELECT COALESCE(tier, 'normal') FROM sessions WHERE id = ?",
            arguments: [sessionId]
        ) == SessionTier.skip.rawValue
    }

    /// docs/invariants.md #3/#5: rebuild every non-skip live FTS row, including
    /// hidden/orphan sessions that remain fetchable by id. Only skip-tier rows
    /// are intentionally omitted from the swapped index.
    private static func eligibleSessionSQLPredicate(alias: String = "s") -> String {
        """
        COALESCE(\(alias).tier, 'normal') != 'skip'
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

    /// All drain/count/finalize callers use the same ownership-first branch.
    /// An unavailable capture is never reclassified as a legacy filesystem job.
    static func recoverableJobEligibility(
        _ db: Database, enabledSources: Set<SourceName>?, capturePolicy: CaptureFTSReadinessPolicy?
    ) throws -> (sql: String, arguments: StatementArguments) {
        let ownership = try captureOwnershipSQL(db)
        let capture = try captureEligibility(db, policy: capturePolicy)
        let known = SourceName.allCases.map(\.rawValue)
        let enabled = enabledSources?.map(\.rawValue).sorted()
        let legacyEnabled = enabled.map { $0.isEmpty ? "0" : "s.source IN (\(placeholders($0.count)))" } ?? "1"
        var arguments = capture?.arguments ?? StatementArguments()
        for value in known { arguments += [value] }
        for value in enabled ?? [] { arguments += [value] }
        let captureSQL = capture.map { "EXISTS (SELECT 1 FROM \(captureAuthorityTables) WHERE \($0.sql))" } ?? "0"
        return ("""
            CASE WHEN \(ownership) THEN \(captureSQL) ELSE (
                j.job_kind != 'fts' OR s.id IS NULL OR s.tier = 'skip'
                OR s.source NOT IN (\(placeholders(known.count))) OR \(legacyEnabled)
            ) END
            """, arguments)
    }

    static func isCaptureOwned(_ db: Database, sessionID: String) throws -> Bool {
        let ownership = try captureOwnershipSQL(db)
        return try Bool.fetchOne(db, sql: """
            SELECT \(ownership) FROM (SELECT ? AS session_id) AS j
            LEFT JOIN sessions AS s ON s.id = j.session_id
            """, arguments: [sessionID]) ?? false
    }

    private static func captureOwnershipSQL(_ db: Database) throws -> String {
        let binding = try tableExists(db, "capture_ingest_identity_bindings")
            ? "EXISTS (SELECT 1 FROM capture_ingest_identity_bindings owned WHERE owned.stored_session_id = j.session_id)"
            : "0"
        return """
            (j.session_id GLOB 'remote:capture-v1.*'
             OR COALESCE(s.authoritative_node GLOB 'capture-v1.*', 0) OR \(binding))
            """
    }

    // These joins seek the unique stored-session binding and its single current
    // generation. No transcript or unbounded generation-history scan is involved.
    private static let captureAuthorityTables = """
        capture_ingest_identity_bindings AS b
        JOIN capture_ingest_generations AS g ON g.generation_id = b.last_parsed_generation_id
        JOIN capture_ingest_source_registry AS r
          ON r.machine_id = g.machine_id AND r.source_instance_id = g.source_instance_id
        JOIN capture_ingest_ledger AS l
          ON l.publication_sha256 = g.publication_sha256 AND l.parser_revision = g.parser_revision
        """

    private static func captureEligibility(
        _ db: Database, policy: CaptureFTSReadinessPolicy?
    ) throws -> (sql: String, arguments: StatementArguments)? {
        guard let policy, !policy.enabledSources.isEmpty else { return nil }
        do { try CaptureIngestNormalizedStore.validateParserRevision(policy.parserRevision) }
        catch { return nil }
        if let deadline = policy.deadline, ContinuousClock.now >= deadline { return nil }
        for table in ["capture_ingest_identity_bindings", "capture_ingest_generations",
                      "capture_ingest_source_registry", "capture_ingest_epoch_history",
                      "capture_ingest_ledger", "capture_ingest_publications"] {
            guard try tableExists(db, table) else { return nil }
        }
        let sources = policy.enabledSources.map(\.rawValue).sorted()
        let validSiblingRoot = captureRegistryRootValidity(alias: "sibling")
        var arguments: StatementArguments = [policy.parserRevision]
        for value in sources { arguments += [value] }
        // Payload schema/count/length corruption is deliberately not filtered:
        // still-current corrupt artifacts need a bounded safe-code retry, not a
        // permanently due hot loop. The loader enforces budgets before BLOB delivery.
        return ("""
            b.stored_session_id = j.session_id AND g.stored_session_id = b.stored_session_id
            AND j.job_kind = 'fts' AND g.required_fts_job_id = j.id
            AND j.id = (s.id || ':' || g.sync_version || ':' || g.snapshot_hash || ':fts')
            AND typeof(j.target_sync_version) = 'integer' AND j.target_sync_version = g.sync_version
            AND b.last_sync_version = g.sync_version AND s.sync_version = g.sync_version
            AND s.snapshot_hash COLLATE BINARY = g.snapshot_hash
            AND typeof(s.authoritative_node) = 'text' AND typeof(s.source) = 'text'
            AND typeof(s.sync_version) = 'integer' AND typeof(s.snapshot_hash) = 'text'
            AND s.tier IN ('skip', 'lite', 'normal', 'premium')
            AND s.authoritative_node COLLATE BINARY = ('capture-v1.' || g.machine_id || '.' || g.source_instance_id)
            AND s.source = g.source AND COALESCE(s.offload_state, 'local') != 'offloaded'
            AND b.machine_id = g.machine_id AND b.source_instance_id = g.source_instance_id
            AND b.source = g.source AND b.native_id COLLATE BINARY = g.native_id
            AND r.source = g.source AND r.parse_format = g.parse_format
            AND r.configured_root COLLATE BINARY = g.configured_root
            AND r.approved_epoch COLLATE BINARY = g.collector_epoch
            AND r.authority_generation = g.authority_generation
            AND EXISTS (
                SELECT 1 FROM capture_ingest_epoch_history AS h
                WHERE h.machine_id = r.machine_id AND h.source_instance_id = r.source_instance_id
                  AND h.authority_generation = r.authority_generation
                  AND h.approved_epoch COLLATE BINARY = r.approved_epoch
            )
            AND NOT EXISTS (
                SELECT 1 FROM capture_ingest_source_registry AS sibling
                WHERE sibling.machine_id = r.machine_id AND sibling.source = r.source
                  AND (
                    NOT COALESCE((\(validSiblingRoot)), 0)
                    OR (sibling.source_instance_id != r.source_instance_id AND (
                        sibling.configured_root COLLATE BINARY = r.configured_root
                        OR substr(r.configured_root, 1, length(sibling.configured_root) + 1) COLLATE BINARY = sibling.configured_root || '/'
                        OR substr(sibling.configured_root, 1, length(r.configured_root) + 1) COLLATE BINARY = r.configured_root || '/'
                    ))
                  )
            )
            AND g.parser_revision COLLATE BINARY = ? AND g.source IN (\(placeholders(sources.count)))
            AND (l.status = 'parsed' OR (l.status = 'index_ready' AND b.last_ready_generation_id = g.generation_id))
            AND l.failure_code IS NULL AND l.claim_token IS NULL AND l.claim_started_at IS NULL
            AND l.claim_expires_at IS NULL AND l.retry_after IS NULL
            """, arguments)
    }

    // Mirror the registry's scalar root/history validation without delivering
    // manifest or normalized BLOBs. A broken sibling invalidates registry lookup
    // too; checking only the selected source-instance leaves permanently due work.
    private static func captureRegistryRootValidity(alias: String) -> String {
        let uuids = ["machine_id", "source_instance_id", "approved_epoch"].map { column -> String in
            let value = "\(alias).\(column)"
            return """
                typeof(\(value)) = 'text' AND length(\(value)) = 36
                AND substr(\(value), 9, 1) = '-' AND substr(\(value), 14, 1) = '-'
                AND substr(\(value), 19, 1) = '-' AND substr(\(value), 24, 1) = '-'
                AND length(replace(\(value), '-', '')) = 32
                AND replace(\(value), '-', '') NOT GLOB '*[^0-9A-F]*'
                """
        }.joined(separator: " AND ")
        return """
            \(uuids)
            AND typeof(\(alias).authority_generation) = 'integer' AND \(alias).authority_generation > 0
            AND typeof(\(alias).configured_root) = 'text' AND length(\(alias).configured_root) > 1
            AND substr(\(alias).configured_root, 1, 1) = '/' AND substr(\(alias).configured_root, -1) != '/'
            AND instr(\(alias).configured_root, char(0)) = 0 AND instr(\(alias).configured_root, '//') = 0
            AND instr(\(alias).configured_root || '/', '/./') = 0 AND instr(\(alias).configured_root || '/', '/../') = 0
            AND EXISTS (
                SELECT 1 FROM capture_ingest_epoch_history AS history
                WHERE history.machine_id = \(alias).machine_id AND history.source_instance_id = \(alias).source_instance_id
                  AND history.authority_generation = \(alias).authority_generation
                  AND history.approved_epoch COLLATE BINARY = \(alias).approved_epoch
            )
            """
    }

    struct CaptureJobAuthority: Sendable {
        let generationID: String
        let values: [DatabaseValue]

        func matches(_ other: Self) -> Bool {
            guard generationID == other.generationID, values.count == other.values.count else { return false }
            return zip(values, other.values).allSatisfy { left, right in
                switch (left.storage, right.storage) {
                case (.null, .null): return true
                case let (.string(a), .string(b)): return a.utf8.elementsEqual(b.utf8)
                case let (.int64(a), .int64(b)): return a == b
                case let (.double(a), .double(b)): return a.bitPattern == b.bitPattern
                case let (.blob(a), .blob(b)): return a == b
                default: return false
                }
            }
        }
    }

    /// Freeze only small scalar authority fields, including the complete job
    /// attempt tuple. Recheck before both readiness and corruption retry writes.
    static func captureJobAuthority(
        _ db: Database, jobID: String, policy: CaptureFTSReadinessPolicy?
    ) throws -> CaptureJobAuthority? {
        guard let eligibility = try captureEligibility(db, policy: policy) else { return nil }
        var arguments = eligibility.arguments
        arguments += [jobID]
        guard let row = try Row.fetchOne(db, sql: """
            SELECT g.generation_id, j.id, j.session_id, j.job_kind, j.target_sync_version,
                j.status, j.retry_count, j.not_before, j.last_error,
                b.machine_id, b.source_instance_id, b.source, b.native_id, b.stored_session_id,
                b.last_parsed_generation_id, b.last_ready_generation_id, b.last_sync_version,
                g.publication_sha256, g.parser_revision, g.parse_format, g.configured_root,
                g.collector_epoch, g.authority_generation, g.sequence, g.required_fts_job_id,
                g.sync_version, g.snapshot_hash, g.normalized_schema_version,
                g.normalized_message_count, g.normalized_messages_sha256,
                typeof(g.normalized_messages_json), length(g.normalized_messages_json),
                r.source, r.parse_format, r.configured_root, r.approved_epoch, r.authority_generation,
                s.authoritative_node, s.source, s.sync_version, s.snapshot_hash, s.tier, s.summary, s.offload_state,
                l.status, l.failure_code, l.claim_token, l.claim_started_at, l.claim_expires_at, l.retry_after
            FROM \(captureAuthorityTables)
            JOIN sessions AS s ON s.id = b.stored_session_id
            JOIN session_index_jobs AS j ON j.session_id = s.id
            WHERE \(eligibility.sql) AND j.id = ?
              AND j.status IN ('pending', 'failed_retryable')
              AND (j.not_before IS NULL OR j.not_before <= datetime('now'))
            """, arguments: arguments) else { return nil }
        guard case .string(let generationID) = (row["generation_id"] as DatabaseValue).storage else { return nil }
        return CaptureJobAuthority(generationID: generationID, values: Array(row.databaseValues))
    }

    private static func placeholders(_ count: Int) -> String { Array(repeating: "?", count: count).joined(separator: ", ") }

    static func recoverableFtsJobCount(
        _ db: GRDB.Database,
        enabledSources: Set<SourceName>? = nil,
        capturePolicy: CaptureFTSReadinessPolicy? = nil
    ) throws -> Int {
        guard try tableExists(db, "session_index_jobs") else { return 0 }
        let eligibility = try recoverableJobEligibility(db, enabledSources: enabledSources, capturePolicy: capturePolicy)
        return try Int.fetchOne(
            db,
            sql: """
            SELECT COUNT(*)
            FROM session_index_jobs AS j
            LEFT JOIN sessions AS s ON s.id = j.session_id
            WHERE j.job_kind = 'fts'
              AND j.status IN ('pending', 'failed_retryable')
              AND (j.not_before IS NULL OR j.not_before <= datetime('now'))
              AND (\(eligibility.sql))
            """,
            arguments: eligibility.arguments
        ) ?? 0
    }

    /// Includes deferred rows so the service does not mistake a debounce window
    /// for an empty FTS backlog. The due-only count above remains authoritative
    /// for rebuild finalization (docs/invariants.md #5).
    static func recoverableFtsBacklog(
        _ db: GRDB.Database,
        enabledSources: Set<SourceName>? = nil,
        capturePolicy: CaptureFTSReadinessPolicy? = nil
    ) throws -> (count: Int, nextDelaySeconds: Int?, hasDeferredRetryable: Bool) {
        guard try tableExists(db, "session_index_jobs") else { return (0, nil, false) }
        let eligibility = try recoverableJobEligibility(db, enabledSources: enabledSources, capturePolicy: capturePolicy)
        guard let row = try Row.fetchOne(
            db,
            sql: """
            SELECT
              COUNT(*) AS backlog_count,
              MIN(
                CASE
                  WHEN j.not_before IS NULL OR j.not_before <= datetime('now') THEN 0
                  ELSE MIN(
                    90,
                    MAX(1, CAST(strftime('%s', j.not_before) - strftime('%s', 'now') AS INTEGER))
                  )
                END
              ) AS next_delay_seconds,
              MAX(
                CASE
                  WHEN j.status = 'failed_retryable'
                    AND j.not_before > datetime('now') THEN 1
                  ELSE 0
                END
              ) AS has_deferred_retryable
            FROM session_index_jobs AS j
            LEFT JOIN sessions AS s ON s.id = j.session_id
            WHERE j.job_kind = 'fts'
              AND j.status IN ('pending', 'failed_retryable')
              AND (\(eligibility.sql))
            """,
            arguments: eligibility.arguments
        ) else {
            return (0, nil, false)
        }
        let deferredRetryable: Int = row["has_deferred_retryable"] ?? 0
        return (row["backlog_count"] ?? 0, row["next_delay_seconds"], deferredRetryable != 0)
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
