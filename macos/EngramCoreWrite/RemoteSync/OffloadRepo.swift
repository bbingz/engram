import Foundation
import GRDB
import EngramCoreRead

/// All offload/rehydrate database mutations. Every function operates on a raw
/// `Database` so callers run them inside the single-writer gate
/// (`ServiceWriterGate.performWriteCommand { writer in writer.write { db in ... } }`).
/// Network I/O is NOT done here — it happens between the claim and commit steps,
/// outside the gate (see the service coordinator / `OffloadRunner`).
public enum OffloadRepo {
    public struct ClaimedJob: Sendable, Equatable {
        public let queueId: String
        public let sessionId: String
        public let syncVersion: Int?

        public init(queueId: String, sessionId: String, syncVersion: Int? = nil) {
            self.queueId = queueId
            self.sessionId = sessionId
            self.syncVersion = syncVersion
        }
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
    /// queue row. MUST run only after a successful PUT or a verified matching GET.
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
            SELECT q.id, q.session_id, s.sync_version
            FROM rehydrate_queue q
            JOIN sessions s ON s.id = q.session_id
            WHERE q.status = 'pending'
            ORDER BY q.created_at, q.id
            LIMIT ?
            """,
            arguments: [limit]
        )
        let claimed = rows.map {
            ClaimedJob(queueId: $0["id"], sessionId: $0["session_id"], syncVersion: $0["sync_version"] ?? 0)
        }
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
        expectedSyncVersion: Int,
        peer: String?
    ) throws {
        try db.execute(
            sql: """
            UPDATE sessions
            SET summary = ?, summary_message_count = ?, offload_state = 'local'
            WHERE id = ? AND sync_version = ? AND offload_state = 'offloaded'
            """,
            arguments: [bundle.summary, bundle.summaryMessageCount, bundle.sessionId, expectedSyncVersion]
        )
        guard db.changesCount == 1 else {
            throw RemoteSyncError.offloadStale(sessionId: bundle.sessionId)
        }
        try FTSRebuildPolicy.replaceFtsContent(db, sessionId: bundle.sessionId, contents: bundle.ftsContents)
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

    /// Reset a claimed rehydrate back to pending (e.g. stale-version abort), so
    /// the next cycle re-checks the session's current offload state/version.
    public static func requeueRehydrate(_ db: Database, queueId: String) throws {
        try db.execute(
            sql: "UPDATE rehydrate_queue SET status = 'pending', updated_at = datetime('now') WHERE id = ?",
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
        public let agentRole: String?
        public let parentSessionId: String?
        public let suggestedParentId: String?
        public let syncVersion: Int
        public let snapshotHash: String
        public let ftsContents: [String]
        /// Latest published bundle identity for the requested live peer.
        public let publishedContentHash: String?
        /// True when the source row has not been indexed since that ledger row.
        /// In that case `ftsContents` is intentionally empty: callers can reuse
        /// `publishedContentHash` without reading or hashing the FTS corpus.
        public let bundleIsCurrent: Bool
        /// True only when FTS has no versioned job history (legacy row), or the
        /// job targeting this exact session version completed successfully.
        public let ftsSnapshotReady: Bool
    }

    public struct LivePublishDeltaToken: Sendable, Equatable {
        public struct ReadySession: Sendable, Equatable {
            public let id: String
            public let syncVersion: Int
            public let snapshotHash: String

            public init(id: String, syncVersion: Int, snapshotHash: String) {
                self.id = id
                self.syncVersion = syncVersion
                self.snapshotHash = snapshotHash
            }
        }

        public let readySessions: [ReadySession]
        public let retractionSessionIds: [String]

        public init(readySessions: [ReadySession], retractionSessionIds: [String]) {
            self.readySessions = readySessions
            self.retractionSessionIds = retractionSessionIds
        }
    }

    /// Scope a project by case-insensitive `project` OR the deterministic dev cwd,
    /// because `project` is inconsistently cased across adapters but the cwd is not.
    /// A BLANK cwd is treated as "no cwd scope" (the `? <> ''` guard) so a missing
    /// cwd falls back to project-only matching instead of sweeping in every session
    /// whose cwd column is empty. Bound args are always `[project, cwd, cwd]`.
    private static let projectScopeSQL =
        "(lower(COALESCE(project, '')) = lower(?) OR (? <> '' AND cwd = ?))"

    private static func livePublishableSessionSQL(alias: String) -> String {
        """
        (\(alias).origin IS NULL OR \(alias).origin = 'local')
          AND \(SessionVisibilityFilter.nonSkipTierSQL(alias: alias))
          AND \(alias).agent_role IS NULL
          AND COALESCE(\(alias).offload_state, 'local') = 'local'
          AND \(alias).parent_session_id IS NULL
          AND \(alias).suggested_parent_id IS NULL
        """
    }

    private static let changedLivePublishCandidateSQL =
        "(latest.content_hash IS NULL OR latest.source_sync_version IS NULL OR latest.source_sync_version != s.sync_version OR latest.source_snapshot_hash IS NULL OR latest.source_snapshot_hash != COALESCE(s.snapshot_hash, ''))"

    /// Local-origin top-level sessions of a project, eligible to PUSH. Excluded:
    /// imported rows (origin = a peer) and skip/agent-role rows (echo-loop guard), and
    /// already-OFFLOADED rows — pushing an offloaded session would read its collapsed
    /// one-line FTS shadow and republish that as the session's content, also
    /// overwriting the rehydrate ledger key. The subagent guard is explicit on
    /// `agent_role` (not just `tier != 'skip'`) for defense-in-depth symmetry with
    /// `OffloadPolicy.isEligible`. Top-level matches browse roots: both
    /// `parent_session_id` and `suggested_parent_id` must be NULL.
    public static func pushCandidates(
        _ db: Database,
        project: String,
        cwd: String,
        limit: Int = .max,
        afterStart: String? = nil,
        afterId: String? = nil
    ) throws -> [PushCandidate] {
        let page = max(1, limit)
        let select = """
        SELECT s.id, s.source, s.start_time, s.end_time, s.generated_title, s.custom_name, s.project,
               s.message_count, s.user_message_count, s.assistant_message_count,
               s.system_message_count, s.tool_message_count, s.summary, s.summary_message_count,
               s.size_bytes, s.tier, s.agent_role, s.parent_session_id, s.suggested_parent_id,
               s.sync_version, COALESCE(s.snapshot_hash, '') AS snapshot_hash
        FROM sessions s
        WHERE (lower(COALESCE(s.project, '')) = lower(?) OR (? <> '' AND s.cwd = ?))
          AND (s.origin IS NULL OR s.origin = 'local')
          AND \(SessionVisibilityFilter.nonSkipTierSQL(alias: "s"))
          AND s.agent_role IS NULL
          AND COALESCE(s.offload_state, 'local') = 'local'
          AND s.parent_session_id IS NULL
          AND s.suggested_parent_id IS NULL
        """
        let order = """
        ORDER BY s.start_time, s.id
        LIMIT ?
        """
        let rows: [Row]
        if let afterStart, let afterId {
            rows = try Row.fetchAll(
                db,
                sql: """
                \(select)
                  AND (
                    s.start_time > ?
                    OR (s.start_time = ? AND s.id > ?)
                  )
                \(order)
                """,
                arguments: [project, cwd, cwd, afterStart, afterStart, afterId, page]
            )
        } else {
            rows = try Row.fetchAll(
                db,
                sql: "\(select)\n\(order)",
                arguments: [project, cwd, cwd, page]
            )
        }
        return try rows.map { try pushCandidate(from: $0, db: db) }
    }

    /// Same publishable predicates as `pushCandidates`, without a project scope.
    /// Pages by `(start_time, id)` so equal timestamps cannot skip a row.
    public static func livePublishCandidates(
        _ db: Database,
        limit: Int,
        afterStart: String? = nil,
        afterId: String? = nil,
        peer: String? = nil,
        includeFtsContents: Bool = true,
        onlyChanged: Bool = false
    ) throws -> [PushCandidate] {
        let page = max(1, limit)
        let ftsReady = liveFTSSnapshotReadySQL(sessionAlias: "s")
        let predicate = livePublishableSessionSQL(alias: "s")
        let select = """
        SELECT s.id, s.source, s.start_time, s.end_time, s.generated_title, s.custom_name, s.project,
               s.message_count, s.user_message_count, s.assistant_message_count,
               s.system_message_count, s.tool_message_count, s.summary, s.summary_message_count,
               s.size_bytes, s.tier, s.agent_role, s.parent_session_id, s.suggested_parent_id,
               s.sync_version, COALESCE(s.snapshot_hash, '') AS snapshot_hash,
               latest.content_hash AS published_content_hash,
               \(ftsReady) AS fts_snapshot_ready,
               CASE
                 WHEN latest.content_hash IS NOT NULL
                  AND latest.source_sync_version = s.sync_version
                  AND latest.source_snapshot_hash = COALESCE(s.snapshot_hash, '')
                  AND \(ftsReady)
                 THEN 1 ELSE 0
               END AS bundle_is_current
        FROM sessions s
        LEFT JOIN (
            SELECT session_id, content_hash, source_sync_version, source_snapshot_hash, synced_at,
                   ROW_NUMBER() OVER (PARTITION BY session_id ORDER BY synced_at DESC, id DESC) AS rn
            FROM sync_ledger
            WHERE remote_peer = ? AND direction = 'out' AND content_hash IS NOT NULL
        ) latest ON latest.session_id = s.id AND latest.rn = 1
        WHERE \(predicate)
          AND \(ftsReady)
        """
        let changed = onlyChanged
            ? "AND \(changedLivePublishCandidateSQL)"
            : ""
        let order = """
        ORDER BY s.start_time, s.id
        LIMIT ?
        """
        let rows: [Row]
        if let afterStart, let afterId {
            rows = try Row.fetchAll(
                db,
                sql: """
                \(select)
                  \(changed)
                  AND (
                    s.start_time > ?
                    OR (s.start_time = ? AND s.id > ?)
                  )
                \(order)
                """,
                arguments: [peer, afterStart, afterStart, afterId, page]
            )
        } else {
            rows = try Row.fetchAll(
                db,
                sql: "\(select)\n\(changed)\n\(order)",
                arguments: [peer, page]
            )
        }
        return try rows.map { try pushCandidate(from: $0, db: db, includeFtsContents: includeFtsContents) }
    }

    /// Unready FTS rows do not consume a publish page, but they still prevent a
    /// complete manifest from certifying the local snapshot set.
    public static func hasUnreadyLivePublishCandidates(_ db: Database) throws -> Bool {
        let ftsReady = liveFTSSnapshotReadySQL(sessionAlias: "s")
        let predicate = livePublishableSessionSQL(alias: "s")
        return try Bool.fetchOne(
            db,
            sql: """
            SELECT EXISTS(
                SELECT 1 FROM sessions s
                WHERE \(predicate)
                  AND NOT \(ftsReady)
            )
            """
        ) ?? false
    }

    public static func hasLivePublishDelta(_ db: Database, peer: String) throws -> Bool {
        if try !livePublishCandidates(
            db,
            limit: 1,
            peer: peer,
            includeFtsContents: false,
            onlyChanged: true
        ).isEmpty {
            return true
        }

        return try !livePublishedRetractionSessionIds(db, peer: peer).isEmpty
    }

    /// Stable identity of the actual outbound delta in one read snapshot.
    /// It deliberately excludes FTS payloads and unrelated writer/job activity.
    public static func livePublishDeltaToken(
        _ db: Database,
        peer: String
    ) throws -> LivePublishDeltaToken? {
        let ftsReady = liveFTSSnapshotReadySQL(sessionAlias: "s")
        let predicate = livePublishableSessionSQL(alias: "s")
        let rows = try Row.fetchAll(
            db,
            sql: """
            SELECT s.id, s.sync_version, COALESCE(s.snapshot_hash, '') AS snapshot_hash
            FROM sessions s
            LEFT JOIN (
                SELECT session_id, content_hash, source_sync_version, source_snapshot_hash,
                       ROW_NUMBER() OVER (
                         PARTITION BY session_id ORDER BY synced_at DESC, id DESC
                       ) AS rn
                FROM sync_ledger
                WHERE remote_peer = ? AND direction = 'out' AND content_hash IS NOT NULL
            ) latest ON latest.session_id = s.id AND latest.rn = 1
            WHERE \(predicate)
              AND \(ftsReady)
              AND \(changedLivePublishCandidateSQL)
            ORDER BY s.start_time, s.id
            """,
            arguments: [peer]
        )
        let readySessions = rows.map { row in
            LivePublishDeltaToken.ReadySession(
                id: row["id"],
                syncVersion: row["sync_version"],
                snapshotHash: row["snapshot_hash"]
            )
        }
        let retractionSessionIds = try livePublishedRetractionSessionIds(db, peer: peer)
        guard !readySessions.isEmpty || !retractionSessionIds.isEmpty else { return nil }
        return LivePublishDeltaToken(
            readySessions: readySessions,
            retractionSessionIds: retractionSessionIds
        )
    }

    public static func livePublishedRetractionSessionIds(
        _ db: Database,
        peer: String
    ) throws -> [String] {
        let predicate = livePublishableSessionSQL(alias: "s")
        return try String.fetchAll(
            db,
            sql: """
            SELECT latest.session_id
            FROM (
                SELECT session_id,
                       ROW_NUMBER() OVER (
                         PARTITION BY session_id ORDER BY synced_at DESC, id DESC
                       ) AS rn
                FROM sync_ledger
                WHERE direction = 'out'
                  AND remote_peer = ?
                  AND remote_key IS NOT NULL AND content_hash IS NOT NULL
            ) latest
            LEFT JOIN sessions s ON s.id = latest.session_id
            WHERE latest.rn = 1
              AND (s.id IS NULL OR NOT (\(predicate)))
            ORDER BY latest.session_id
            """,
            arguments: [peer]
        )
    }

    /// Latest `out` ledger row per session for this peer, joined to still-
    /// publishable local-origin rows. Unlike `publishedManifestEntries`, this
    /// does not rewrite `project` and refuses offloaded rows.
    public static func livePublishedEntries(_ db: Database, peer: String) throws -> [SyncManifestEntry] {
        let predicate = livePublishableSessionSQL(alias: "s")
        let rows = try Row.fetchAll(
            db,
            sql: """
            SELECT s.id, s.source, s.project, s.generated_title, s.custom_name,
                   s.start_time, s.end_time, s.message_count, s.user_message_count,
                   s.assistant_message_count, s.system_message_count, s.tool_message_count,
                   s.summary, s.summary_message_count, s.size_bytes, s.tier,
                   s.agent_role, s.parent_session_id, s.suggested_parent_id,
                   l.remote_key, l.content_hash
            FROM sessions s
            JOIN (
                SELECT session_id, remote_key, content_hash,
                       ROW_NUMBER() OVER (PARTITION BY session_id ORDER BY synced_at DESC, id DESC) AS rn
                FROM sync_ledger
                WHERE direction = 'out'
                  AND remote_peer = ?
                  AND remote_key IS NOT NULL AND content_hash IS NOT NULL
            ) l ON l.session_id = s.id AND l.rn = 1
            WHERE \(predicate)
            ORDER BY s.start_time, s.id
            """,
            arguments: [peer]
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
                contentHash: row["content_hash"],
                agentRole: row["agent_role"],
                parentSessionId: row["parent_session_id"],
                suggestedParentId: row["suggested_parent_id"]
            )
        }
    }

    /// Live-path only: drop older `out` rows for `(peer, session_id)` after a
    /// newer hash is recorded. Does not change `publishOnlyCommit`.
    public static func compactLivePublishLedger(_ db: Database, peer: String, sessionId: String) throws {
        guard let keepId = try Int64.fetchOne(
            db,
            sql: """
            SELECT id FROM sync_ledger
            WHERE session_id = ? AND remote_peer = ? AND direction = 'out'
            ORDER BY synced_at DESC, id DESC
            LIMIT 1
            """,
            arguments: [sessionId, peer]
        ) else { return }
        try db.execute(
            sql: """
            DELETE FROM sync_ledger
            WHERE session_id = ? AND remote_peer = ? AND direction = 'out' AND id != ?
            """,
            arguments: [sessionId, peer, keepId]
        )
    }

    /// Drop outbound membership only after a complete live head has omitted it.
    public static func acknowledgeLivePublishedRetractions(
        _ db: Database,
        peer: String,
        sessionIds: [String]
    ) throws {
        for sessionId in Set(sessionIds) {
            try db.execute(
                sql: """
                DELETE FROM sync_ledger
                WHERE session_id = ? AND remote_peer = ? AND direction = 'out'
                """,
                arguments: [sessionId, peer]
            )
        }
    }

    /// Confirms a live bundle only while the local row is still the exact
    /// snapshot read before network I/O. The stored version and snapshot hash
    /// are also the currentness predicate for later zero-FTS-read cycles.
    public static func commitLivePublishedSnapshot(
        _ db: Database,
        sessionId: String,
        remoteKey: String,
        contentHash: String,
        peer: String,
        expectedSyncVersion: Int,
        expectedSnapshotHash: String
    ) throws -> Bool {
        let ftsReady = liveFTSSnapshotReadySQL(sessionAlias: "s")
        guard try Bool.fetchOne(
            db,
            sql: """
            SELECT EXISTS(
                SELECT 1 FROM sessions s
                WHERE s.id = ? AND s.sync_version = ?
                  AND COALESCE(s.snapshot_hash, '') = ?
                  AND \(ftsReady)
            )
            """,
            arguments: [sessionId, expectedSyncVersion, expectedSnapshotHash]
        ) == true else { return false }

        let latest = try Row.fetchOne(
            db,
            sql: """
            SELECT id, content_hash FROM sync_ledger
            WHERE session_id = ? AND remote_peer = ? AND direction = 'out'
            ORDER BY synced_at DESC, id DESC
            LIMIT 1
            """,
            arguments: [sessionId, peer]
        )
        let latestHash: String? = latest?["content_hash"]
        if let latest, latestHash == contentHash {
            let id: Int64 = latest["id"]
            try db.execute(
                sql: """
                UPDATE sync_ledger
                SET remote_session_id = ?, remote_key = ?, source_sync_version = ?,
                    source_snapshot_hash = ?,
                    synced_at = datetime('now')
                WHERE id = ?
                """,
                arguments: [sessionId, remoteKey, expectedSyncVersion, expectedSnapshotHash, id]
            )
        } else {
            try db.execute(
                sql: """
                INSERT INTO sync_ledger(
                    session_id, remote_peer, remote_session_id, remote_key,
                    direction, content_hash, source_sync_version, source_snapshot_hash
                ) VALUES (?, ?, ?, ?, 'out', ?, ?, ?)
                """,
                arguments: [
                    sessionId, peer, sessionId, remoteKey, contentHash,
                    expectedSyncVersion, expectedSnapshotHash,
                ]
            )
        }
        return true
    }

    private static func pushCandidate(
        from row: Row,
        db: Database,
        includeFtsContents: Bool = true
    ) throws -> PushCandidate {
        let id: String = row["id"]
        let hasLiveState = row.columnNames.contains("bundle_is_current")
        let bundleIsCurrent: Bool = hasLiveState && ((row["bundle_is_current"] as Int?) ?? 0) == 1
        let ftsSnapshotReady: Bool = !hasLiveState || ((row["fts_snapshot_ready"] as Int?) ?? 0) == 1
        let publishedContentHash: String? = hasLiveState ? row["published_content_hash"] : nil
        let contents: [String]
        if includeFtsContents, ftsSnapshotReady, !bundleIsCurrent {
            contents = try String.fetchAll(
                db, sql: "SELECT content FROM sessions_fts WHERE session_id = ?", arguments: [id]
            )
        } else {
            contents = []
        }
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
            agentRole: row["agent_role"],
            parentSessionId: row["parent_session_id"],
            suggestedParentId: row["suggested_parent_id"],
            syncVersion: row["sync_version"] ?? 0,
            snapshotHash: row["snapshot_hash"] ?? "",
            ftsContents: contents,
            publishedContentHash: publishedContentHash,
            bundleIsCurrent: bundleIsCurrent,
            ftsSnapshotReady: ftsSnapshotReady
        )
    }

    private static func liveFTSSnapshotReadySQL(sessionAlias: String) -> String {
        """
        (
          NOT EXISTS (
            SELECT 1 FROM session_index_jobs any_fts
            WHERE any_fts.session_id = \(sessionAlias).id AND any_fts.job_kind = 'fts'
          )
          OR (
            EXISTS (
              SELECT 1 FROM session_index_jobs completed_fts
              WHERE completed_fts.session_id = \(sessionAlias).id
                AND completed_fts.job_kind = 'fts'
                AND completed_fts.target_sync_version = \(sessionAlias).sync_version
                AND completed_fts.status = 'completed'
            )
            AND NOT EXISTS (
              SELECT 1 FROM session_index_jobs incomplete_fts
              WHERE incomplete_fts.session_id = \(sessionAlias).id
                AND incomplete_fts.job_kind = 'fts'
                AND incomplete_fts.target_sync_version = \(sessionAlias).sync_version
                AND incomplete_fts.status != 'completed'
            )
          )
        )
        """
    }

    /// Record a published session WITHOUT collapsing local FTS or flipping
    /// `offload_state` (unlike `commitOffloaded`). Idempotent: skips when an 'out'
    /// row with the same session_id + content_hash already exists, so re-publishing
    /// unchanged content is a no-op for that peer.
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
            WHERE session_id = ? AND remote_peer = ? AND direction = 'out' AND content_hash = ?
            """,
            arguments: [sessionId, peer, contentHash]
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
    ///
    /// Each entry's `project` is normalized to the requested `project` (not the raw
    /// row value), because the pull side matches on project name only — it has no cwd
    /// — so a session scoped in by the `cwd` branch with a NULL/divergent project
    /// would otherwise be uploaded but never importable. The per-peer manifest merge
    /// in `pushProject` also relies on this to identify "this project's slice".
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
                   s.agent_role, s.parent_session_id, s.suggested_parent_id,
                   l.remote_key, l.content_hash
            FROM sessions s
            JOIN (
                SELECT session_id, remote_key, content_hash,
                       ROW_NUMBER() OVER (PARTITION BY session_id ORDER BY synced_at DESC, id DESC) AS rn
                FROM sync_ledger
                WHERE direction = 'out' AND remote_key IS NOT NULL AND content_hash IS NOT NULL
            ) l ON l.session_id = s.id AND l.rn = 1
            WHERE \(projectScopeSQL)
              AND (s.origin IS NULL OR s.origin = 'local')
              -- Invariants 2/3: linking or classifying a session must never make a
              -- skip/subagent/child visible through a previously published row.
              AND \(SessionVisibilityFilter.nonSkipTierSQL(alias: "s"))
              AND s.agent_role IS NULL
              AND s.parent_session_id IS NULL
              AND s.suggested_parent_id IS NULL
            ORDER BY s.start_time
            """,
            arguments: [project, cwd, cwd]
        )
        return rows.map { row in
            let custom: String? = row["custom_name"]
            let generated: String? = row["generated_title"]
            return SyncManifestEntry(
                sessionId: row["id"],
                source: row["source"],
                project: project,
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
                contentHash: row["content_hash"],
                agentRole: row["agent_role"],
                parentSessionId: row["parent_session_id"],
                suggestedParentId: row["suggested_parent_id"]
            )
        }
    }
}
