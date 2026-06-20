import Foundation
import GRDB

/// All offload/rehydrate database mutations. Every function operates on a raw
/// `Database` so callers run them inside the single-writer gate
/// (`ServiceWriterGate.performWriteCommand { writer in writer.write { db in ... } }`).
/// Network I/O is NOT done here — it happens between the claim and commit steps,
/// outside the gate (see the service coordinator / `OffloadRunner`).
public enum OffloadRepo {
    public struct ClaimedJob: Sendable, Equatable {
        public let queueId: String
        public let sessionId: String
    }

    public struct BundleInputs: Sendable, Equatable {
        public let ftsContents: [String]
        public let summary: String?
        public let summaryMessageCount: Int?
        public let messageCount: Int
        public let userMessageCount: Int
        public let assistantMessageCount: Int
        public let toolMessageCount: Int
        public let systemMessageCount: Int
        public let generatedTitle: String?
        public let project: String?
        /// Captured at read time so the commit can detect a concurrent re-index
        /// (sync_version change) and abort instead of collapsing fresh content.
        public let syncVersion: Int
    }

    /// After this many failed attempts a queue job is marked terminally 'failed'
    /// instead of retried.
    public static let maxAttempts = 5

    /// Reclaim `inflight` jobs left behind by a crashed/cancelled prior cycle.
    /// Only rows untouched for `olderThanSeconds` are reset, so a concurrently
    /// in-flight cycle (fresh `updated_at`) is never disturbed.
    @discardableResult
    public static func requeueStaleInflight(_ db: Database, olderThanSeconds: Int = 600) throws -> Int {
        let cutoff = "-\(olderThanSeconds) seconds"
        var total = 0
        for table in ["offload_queue", "rehydrate_queue"] {
            try db.execute(
                sql: """
                UPDATE \(table)
                SET status = 'pending', updated_at = datetime('now')
                WHERE status = 'inflight' AND updated_at <= datetime('now', ?)
                """,
                arguments: [cutoff]
            )
            total += db.changesCount
        }
        return total
    }

    // MARK: - Offload enqueue

    /// Enqueue `pending` offload jobs for the given sessions, skipping any that
    /// already have an open (pending/inflight) job. Returns the count enqueued.
    @discardableResult
    public static func enqueueOffload(_ db: Database, sessionIds: [String], generation: Int?) throws -> Int {
        var enqueued = 0
        for sessionId in sessionIds {
            let open = try Int.fetchOne(
                db,
                sql: """
                SELECT COUNT(*) FROM offload_queue
                WHERE session_id = ? AND status IN ('pending', 'inflight')
                """,
                arguments: [sessionId]
            ) ?? 0
            guard open == 0 else { continue }
            try db.execute(
                sql: """
                INSERT INTO offload_queue(id, session_id, status, since_generation)
                VALUES (?, ?, 'pending', ?)
                """,
                arguments: [UUID().uuidString, sessionId, generation]
            )
            enqueued += 1
        }
        return enqueued
    }

    /// Candidate rows the policy considers: not yet offloaded. The caller applies
    /// `OffloadPolicy.isEligible`. Excludes rows already offloaded AND imported peer
    /// rows (origin = a peer) — imported sessions are accessed through the peer and
    /// must never be re-offloaded (would collapse imported FTS + insert an 'out'
    /// ledger row, an echo loop the design forbids). Mirrors `pushCandidates`' guard.
    public static func candidateRows(_ db: Database, limit: Int) throws -> [OffloadPolicy.SessionRow] {
        let rows = try Row.fetchAll(
            db,
            sql: """
            SELECT id, offload_state, hidden_at, tier, agent_role, size_bytes,
                   COALESCE(end_time, start_time) AS last_activity
            FROM sessions
            WHERE COALESCE(offload_state, 'local') = 'local'
              AND (origin IS NULL OR origin = 'local')
            ORDER BY size_bytes DESC
            LIMIT ?
            """,
            arguments: [limit]
        )
        return rows.map { row in
            OffloadPolicy.SessionRow(
                id: row["id"],
                offloadState: row["offload_state"],
                hiddenAt: row["hidden_at"],
                tier: row["tier"],
                agentRole: row["agent_role"],
                lastActivity: row["last_activity"],
                sizeBytes: row["size_bytes"] ?? 0
            )
        }
    }

    // MARK: - Offload worker steps

    /// Claim up to `limit` pending offload jobs, flipping them to `inflight` so a
    /// concurrent drain cannot double-process them. Runs in one write tx.
    public static func claimPendingOffload(_ db: Database, limit: Int) throws -> [ClaimedJob] {
        let rows = try Row.fetchAll(
            db,
            sql: """
            SELECT id, session_id FROM offload_queue
            WHERE status = 'pending'
            ORDER BY created_at, id
            LIMIT ?
            """,
            arguments: [limit]
        )
        let claimed = rows.map { ClaimedJob(queueId: $0["id"], sessionId: $0["session_id"]) }
        for job in claimed {
            try db.execute(
                sql: "UPDATE offload_queue SET status = 'inflight', updated_at = datetime('now') WHERE id = ?",
                arguments: [job.queueId]
            )
        }
        return claimed
    }

    /// Read everything needed to build a bundle: the full FTS content lines plus
    /// summary/counts/title/project. Returns nil if the session row is gone.
    public static func bundleInputs(_ db: Database, sessionId: String) throws -> BundleInputs? {
        guard let row = try Row.fetchOne(
            db,
            sql: """
            SELECT summary, summary_message_count, message_count, user_message_count,
                   assistant_message_count, tool_message_count, system_message_count,
                   generated_title, project, sync_version
            FROM sessions WHERE id = ?
            """,
            arguments: [sessionId]
        ) else {
            return nil
        }
        let contents = try String.fetchAll(
            db,
            sql: "SELECT content FROM sessions_fts WHERE session_id = ?",
            arguments: [sessionId]
        )
        return BundleInputs(
            ftsContents: contents,
            summary: row["summary"],
            summaryMessageCount: row["summary_message_count"],
            messageCount: row["message_count"] ?? 0,
            userMessageCount: row["user_message_count"] ?? 0,
            assistantMessageCount: row["assistant_message_count"] ?? 0,
            toolMessageCount: row["tool_message_count"] ?? 0,
            systemMessageCount: row["system_message_count"] ?? 0,
            generatedTitle: row["generated_title"],
            project: row["project"],
            syncVersion: row["sync_version"] ?? 0
        )
    }

    /// Commit a confirmed offload: replace the full FTS rows with the single
    /// keyword-shadow line, flip `offload_state`, record the ledger, finish the
    /// queue row. MUST run only after the remote PUT returned success.
    public static func commitOffloaded(
        _ db: Database,
        queueId: String,
        sessionId: String,
        expectedSyncVersion: Int,
        remoteKey: String,
        contentHash: String,
        shadowLine: String,
        peer: String?
    ) throws {
        // Atomicity guard: flip the state ONLY if the session still matches the
        // version we captured the bundle from and is still local. If it was
        // re-indexed (sync_version changed) or removed in the network window,
        // abort BEFORE touching FTS so we never collapse content that no longer
        // matches the uploaded bundle. The caller re-queues a stale offload.
        try db.execute(
            sql: """
            UPDATE sessions SET offload_state = 'offloaded'
            WHERE id = ? AND sync_version = ? AND COALESCE(offload_state, 'local') = 'local'
            """,
            arguments: [sessionId, expectedSyncVersion]
        )
        guard db.changesCount == 1 else {
            throw RemoteSyncError.offloadStale(sessionId: sessionId)
        }
        // Shadow keeps the session keyword-discoverable; replaceFtsContent updates
        // both the active and (if a rebuild is mid-flight) the rebuild table, so
        // the shadow survives a concurrent FTS rebuild.
        try FTSRebuildPolicy.replaceFtsContent(db, sessionId: sessionId, contents: [shadowLine])
        try db.execute(
            sql: """
            INSERT INTO sync_ledger(session_id, remote_peer, remote_key, direction, content_hash)
            VALUES (?, ?, ?, 'out', ?)
            """,
            arguments: [sessionId, peer, remoteKey, contentHash]
        )
        try db.execute(
            sql: """
            UPDATE offload_queue
            SET status = 'done', remote_key = ?, last_error = NULL, updated_at = datetime('now')
            WHERE id = ?
            """,
            arguments: [remoteKey, queueId]
        )
    }

    /// Reset a claimed offload back to pending (e.g. a stale-version abort), so
    /// the next cycle re-captures the session's current content.
    public static func requeueOffload(_ db: Database, queueId: String) throws {
        try db.execute(
            sql: "UPDATE offload_queue SET status = 'pending', updated_at = datetime('now') WHERE id = ?",
            arguments: [queueId]
        )
    }

    /// Mark a failed attempt: retry (back to 'pending') until `maxAttempts`, then
    /// terminally 'failed'. A transient network error therefore no longer abandons
    /// the session permanently.
    public static func failOffload(_ db: Database, queueId: String, error: String) throws {
        try db.execute(
            sql: """
            UPDATE offload_queue
            SET status = CASE WHEN attempts + 1 >= ? THEN 'failed' ELSE 'pending' END,
                attempts = attempts + 1,
                last_error = ?,
                updated_at = datetime('now')
            WHERE id = ?
            """,
            arguments: [maxAttempts, error, queueId]
        )
    }

    // MARK: - Rehydrate

    /// Enqueue a rehydrate for an offloaded session (no-op if not offloaded or a
    /// rehydrate is already open). Returns true if a new job was enqueued.
    @discardableResult
    public static func enqueueRehydrate(_ db: Database, sessionId: String) throws -> Bool {
        let state = try String.fetchOne(
            db, sql: "SELECT offload_state FROM sessions WHERE id = ?", arguments: [sessionId]
        )
        guard state == "offloaded" else { return false }
        let open = try Int.fetchOne(
            db,
            sql: "SELECT COUNT(*) FROM rehydrate_queue WHERE session_id = ? AND status IN ('pending', 'inflight')",
            arguments: [sessionId]
        ) ?? 0
        guard open == 0 else { return false }
        try db.execute(
            sql: "INSERT INTO rehydrate_queue(id, session_id, status) VALUES (?, ?, 'pending')",
            arguments: [UUID().uuidString, sessionId]
        )
        return true
    }

    public static func claimPendingRehydrate(_ db: Database, limit: Int) throws -> [ClaimedJob] {
        let rows = try Row.fetchAll(
            db,
            sql: """
            SELECT id, session_id FROM rehydrate_queue
            WHERE status = 'pending'
            ORDER BY created_at, id
            LIMIT ?
            """,
            arguments: [limit]
        )
        let claimed = rows.map { ClaimedJob(queueId: $0["id"], sessionId: $0["session_id"]) }
        for job in claimed {
            try db.execute(
                sql: "UPDATE rehydrate_queue SET status = 'inflight', updated_at = datetime('now') WHERE id = ?",
                arguments: [job.queueId]
            )
        }
        return claimed
    }

    /// The most recent outbound remote key for a session, used to fetch its bundle.
    public static func latestRemoteKey(_ db: Database, sessionId: String) throws -> String? {
        try String.fetchOne(
            db,
            sql: """
            SELECT remote_key FROM sync_ledger
            WHERE session_id = ? AND direction = 'out' AND remote_key IS NOT NULL
            ORDER BY synced_at DESC, id DESC
            LIMIT 1
            """,
            arguments: [sessionId]
        )
    }

    /// Commit a verified rehydrate: restore the full FTS rows + summary, flip
    /// `offload_state` back to local, record the ledger, finish the queue row.
    public static func commitRehydrated(
        _ db: Database,
        queueId: String,
        bundle: RemoteSessionBundle,
        peer: String?
    ) throws {
        try FTSRebuildPolicy.replaceFtsContent(db, sessionId: bundle.sessionId, contents: bundle.ftsContents)
        try db.execute(
            sql: """
            UPDATE sessions
            SET summary = ?, summary_message_count = ?, offload_state = 'local'
            WHERE id = ?
            """,
            arguments: [bundle.summary, bundle.summaryMessageCount, bundle.sessionId]
        )
        try db.execute(
            sql: """
            INSERT INTO sync_ledger(session_id, remote_peer, remote_key, direction, content_hash)
            VALUES (?, ?, ?, 'in', ?)
            """,
            arguments: [bundle.sessionId, peer, BundleCodec.contentKey(bundle), bundle.contentHash]
        )
        try db.execute(
            sql: """
            UPDATE rehydrate_queue
            SET status = 'done', last_error = NULL, updated_at = datetime('now')
            WHERE id = ?
            """,
            arguments: [queueId]
        )
    }

    /// Retry (back to 'pending') until `maxAttempts`, then terminally 'failed'.
    public static func failRehydrate(_ db: Database, queueId: String, error: String) throws {
        try db.execute(
            sql: """
            UPDATE rehydrate_queue
            SET status = CASE WHEN attempts + 1 >= ? THEN 'failed' ELSE 'pending' END,
                attempts = attempts + 1,
                last_error = ?,
                updated_at = datetime('now')
            WHERE id = ?
            """,
            arguments: [maxAttempts, error, queueId]
        )
    }

    // MARK: - Read helpers

    public static func offloadState(_ db: Database, sessionId: String) throws -> String? {
        try String.fetchOne(db, sql: "SELECT offload_state FROM sessions WHERE id = ?", arguments: [sessionId])
    }

    // MARK: - Session-record sync (Layer 2: publish/manifest)

    /// One local session to publish: bundle inputs (FTS + counts) PLUS the manifest
    /// metadata fields (source/timestamps/title/size/tier) that the bundle does not
    /// carry, so a peer can reconstruct an imported row from manifest + bundle.
    public struct PushCandidate: Sendable, Equatable {
        public let id: String
        public let source: String
        public let startTime: String
        public let endTime: String?
        public let title: String?
        public let project: String?
        public let messageCount: Int
        public let userMessageCount: Int
        public let assistantMessageCount: Int
        public let systemMessageCount: Int
        public let toolMessageCount: Int
        public let summary: String?
        public let summaryMessageCount: Int?
        public let sizeBytes: Int
        public let tier: String?
        public let syncVersion: Int
        public let ftsContents: [String]
    }

    /// Scope a project by case-insensitive `project` OR the deterministic dev cwd,
    /// because `project` is inconsistently cased across adapters but the cwd is not.
    private static let projectScopeSQL =
        "(lower(COALESCE(project, '')) = lower(?) OR cwd = ?)"

    /// Local-origin top-level sessions of a project, eligible to PUSH. Imported rows
    /// (origin = a peer) and skip/subagent rows are excluded to prevent echo loops.
    public static func pushCandidates(_ db: Database, project: String, cwd: String) throws -> [PushCandidate] {
        let rows = try Row.fetchAll(
            db,
            sql: """
            SELECT id, source, start_time, end_time, generated_title, custom_name, project,
                   message_count, user_message_count, assistant_message_count,
                   system_message_count, tool_message_count, summary, summary_message_count,
                   size_bytes, tier, sync_version
            FROM sessions
            WHERE \(projectScopeSQL)
              AND (origin IS NULL OR origin = 'local')
              AND (tier IS NULL OR tier != 'skip')
              AND parent_session_id IS NULL
            ORDER BY start_time
            """,
            arguments: [project, cwd]
        )
        return try rows.map { row in
            let id: String = row["id"]
            let contents = try String.fetchAll(
                db, sql: "SELECT content FROM sessions_fts WHERE session_id = ?", arguments: [id]
            )
            let custom: String? = row["custom_name"]
            let generated: String? = row["generated_title"]
            return PushCandidate(
                id: id,
                source: row["source"],
                startTime: row["start_time"],
                endTime: row["end_time"],
                title: (custom?.isEmpty == false ? custom : generated),
                project: row["project"],
                messageCount: row["message_count"] ?? 0,
                userMessageCount: row["user_message_count"] ?? 0,
                assistantMessageCount: row["assistant_message_count"] ?? 0,
                systemMessageCount: row["system_message_count"] ?? 0,
                toolMessageCount: row["tool_message_count"] ?? 0,
                summary: row["summary"],
                summaryMessageCount: row["summary_message_count"],
                sizeBytes: row["size_bytes"] ?? 0,
                tier: row["tier"],
                syncVersion: row["sync_version"] ?? 0,
                ftsContents: contents
            )
        }
    }

    /// Record a published session WITHOUT collapsing local FTS or flipping
    /// `offload_state` (unlike `commitOffloaded`). Idempotent: skips when an 'out'
    /// row with the same session_id + content_hash already exists, so re-publishing
    /// unchanged content is a no-op.
    public static func publishOnlyCommit(
        _ db: Database,
        sessionId: String,
        remoteKey: String,
        remoteSessionId: String,
        contentHash: String,
        peer: String
    ) throws {
        let existing = try Int.fetchOne(
            db,
            sql: """
            SELECT COUNT(*) FROM sync_ledger
            WHERE session_id = ? AND direction = 'out' AND content_hash = ?
            """,
            arguments: [sessionId, contentHash]
        ) ?? 0
        guard existing == 0 else { return }
        try db.execute(
            sql: """
            INSERT INTO sync_ledger(session_id, remote_peer, remote_session_id, remote_key, direction, content_hash)
            VALUES (?, ?, ?, ?, 'out', ?)
            """,
            arguments: [sessionId, peer, remoteSessionId, remoteKey, contentHash]
        )
    }

    /// Build manifest entries from a project's PUBLISHED sessions: current session
    /// metadata joined to the latest 'out' ledger row (remote_key + content_hash).
    /// `peer` is the publishing identity stamped onto each entry's session id space.
    public static func publishedManifestEntries(
        _ db: Database, project: String, cwd: String, peer _: String
    ) throws -> [SyncManifestEntry] {
        let rows = try Row.fetchAll(
            db,
            sql: """
            SELECT s.id, s.source, s.project, s.generated_title, s.custom_name,
                   s.start_time, s.end_time, s.message_count, s.user_message_count,
                   s.assistant_message_count, s.system_message_count, s.tool_message_count,
                   s.summary, s.summary_message_count, s.size_bytes, s.tier,
                   l.remote_key, l.content_hash
            FROM sessions s
            JOIN (
                SELECT session_id, remote_key, content_hash,
                       ROW_NUMBER() OVER (PARTITION BY session_id ORDER BY synced_at DESC, id DESC) AS rn
                FROM sync_ledger
                WHERE direction = 'out' AND remote_key IS NOT NULL
            ) l ON l.session_id = s.id AND l.rn = 1
            WHERE \(projectScopeSQL)
              AND (s.origin IS NULL OR s.origin = 'local')
            ORDER BY s.start_time
            """,
            arguments: [project, cwd]
        )
        return rows.map { row in
            let custom: String? = row["custom_name"]
            let generated: String? = row["generated_title"]
            return SyncManifestEntry(
                sessionId: row["id"],
                source: row["source"],
                project: row["project"],
                title: (custom?.isEmpty == false ? custom : generated),
                startTime: row["start_time"],
                endTime: row["end_time"],
                messageCount: row["message_count"] ?? 0,
                userMessageCount: row["user_message_count"] ?? 0,
                assistantMessageCount: row["assistant_message_count"] ?? 0,
                systemMessageCount: row["system_message_count"] ?? 0,
                toolMessageCount: row["tool_message_count"] ?? 0,
                summary: row["summary"],
                summaryMessageCount: row["summary_message_count"],
                sizeBytes: row["size_bytes"] ?? 0,
                tier: row["tier"],
                remoteKey: row["remote_key"],
                contentHash: row["content_hash"]
            )
        }
    }
}
