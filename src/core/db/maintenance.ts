// src/core/db/maintenance.ts — post-migration backfills and DB maintenance
import { closeSync, openSync, readSync } from 'node:fs';
import type BetterSqlite3 from 'better-sqlite3';
import {
  DETECTION_VERSION,
  isDispatchPattern,
  pickBestCandidate,
  scoreCandidate,
} from '../parent-detection.js';
import { computeQualityScore } from '../session-scoring.js';
import { addProjectAlias } from './alias-repo.js';
import { finishMigration } from './migration-log-repo.js';
import {
  setParentSession,
  setSuggestedParent,
  validateParentLink,
} from './parent-link-repo.js';

export function runPostMigrationBackfill(db: BetterSqlite3.Database): void {
  // Incremental: only backfill sessions not yet in session_local_state
  // and sessions missing authoritative_node. Safe to run every startup.
  db.prepare(`
    INSERT INTO session_local_state (session_id, hidden_at, custom_name, local_readable_path)
    SELECT id, hidden_at, custom_name, file_path
    FROM sessions
    WHERE id NOT IN (SELECT session_id FROM session_local_state)
  `).run();

  db.prepare(`
    UPDATE sessions
    SET
      authoritative_node = COALESCE(authoritative_node, origin, 'local'),
      source_locator = COALESCE(source_locator, file_path),
      sync_version = COALESCE(sync_version, 0),
      snapshot_hash = COALESCE(snapshot_hash, '')
    WHERE authoritative_node IS NULL OR authoritative_node = ''
  `).run();

  // Only does work when there are unmigrated rows — effectively O(0) on subsequent starts
}

export function backfillTiers(db: BetterSqlite3.Database): void {
  db.exec(`
    UPDATE sessions SET tier = CASE
      WHEN agent_role IS NOT NULL THEN 'skip'
      WHEN file_path LIKE '%/subagents/%' THEN 'skip'
      WHEN message_count <= 1 THEN 'skip'
      WHEN message_count >= 20 THEN 'premium'
      WHEN message_count >= 10 AND project IS NOT NULL THEN 'premium'
      WHEN (julianday(end_time) - julianday(start_time)) * 1440 > 30 THEN 'premium'
      WHEN summary LIKE '%/usage%' THEN 'lite'
      WHEN summary LIKE '%Generate a short, clear title%' THEN 'lite'
      ELSE 'normal'
    END
    WHERE tier IS NULL
  `);
}

export function backfillScores(db: BetterSqlite3.Database): number {
  const rows = db
    .prepare(`
    SELECT id, user_message_count, assistant_message_count, tool_message_count, system_message_count,
           start_time, end_time, project
    FROM sessions
    WHERE (quality_score IS NULL OR quality_score = 0)
      AND tier != 'skip'
      AND (user_message_count > 0 OR assistant_message_count > 0)
  `)
    .all() as {
    id: string;
    user_message_count: number;
    assistant_message_count: number;
    tool_message_count: number;
    system_message_count: number;
    start_time: string;
    end_time: string | null;
    project: string | null;
  }[];

  if (rows.length === 0) return 0;

  const updateStmt = db.prepare(
    'UPDATE sessions SET quality_score = ? WHERE id = ?',
  );
  const transaction = db.transaction(() => {
    for (const row of rows) {
      const score = computeQualityScore({
        userCount: row.user_message_count,
        assistantCount: row.assistant_message_count,
        toolCount: row.tool_message_count,
        systemCount: row.system_message_count,
        startTime: row.start_time,
        endTime: row.end_time,
        project: row.project,
      });
      updateStmt.run(score, row.id);
    }
  });
  transaction();
  return rows.length;
}

export function optimizeFts(db: BetterSqlite3.Database): void {
  db.exec("INSERT INTO sessions_fts(sessions_fts) VALUES('optimize')");
  db.exec("INSERT INTO insights_fts(insights_fts) VALUES('optimize')");
}

export type WalCheckpointMode = 'PASSIVE' | 'FULL' | 'RESTART' | 'TRUNCATE';
export interface WalCheckpointResult {
  busy: number; // 1 if another conn blocked the requested mode
  log: number; // WAL frames at start
  checkpointed: number; // frames moved to main DB
}

// Drive WAL checkpoint from the daemon only. TRUNCATE shrinks the -wal file
// back to zero when possible; readers holding an older snapshot force it to
// fall back to PASSIVE (busy=1) — safe, we retry on the next tick.
export function checkpointWal(
  db: BetterSqlite3.Database,
  mode: WalCheckpointMode = 'TRUNCATE',
): WalCheckpointResult {
  const rows = db.pragma(`wal_checkpoint(${mode})`) as WalCheckpointResult[];
  return rows[0] ?? { busy: 0, log: 0, checkpointed: 0 };
}

export function vacuumIfNeeded(
  db: BetterSqlite3.Database,
  thresholdPct: number,
): boolean {
  const pageCount =
    (db.pragma('page_count') as { page_count: number }[])[0]?.page_count ?? 0;
  const freeCount =
    (db.pragma('freelist_count') as { freelist_count: number }[])[0]
      ?.freelist_count ?? 0;
  if (pageCount === 0) return false;
  const fragPct = (freeCount / pageCount) * 100;
  if (fragPct > thresholdPct) {
    db.exec('VACUUM');
    return true;
  }
  return false;
}

export function deduplicateFilePaths(db: BetterSqlite3.Database): number {
  const result = db
    .prepare(`
    DELETE FROM sessions WHERE rowid NOT IN (
      SELECT MAX(rowid) FROM sessions GROUP BY file_path
    ) AND file_path IS NOT NULL AND file_path != ''
  `)
    .run();
  return result.changes;
}

/**
 * Reconcile `insights` (text+FTS) and `memory_insights` (vector) tables.
 * Fixes divergence caused by crashes, provider changes, etc.
 *
 * 1. insights with has_embedding=1 but no live memory_insights row → reset has_embedding=0
 * 2. memory_insights rows with no matching insights row → soft-delete
 *
 * memory_insights may not exist if sqlite-vec was never loaded — gracefully returns zeros.
 */
export function reconcileInsights(
  db: BetterSqlite3.Database,
  log?: { info: (message: string, data?: Record<string, unknown>) => void },
): { resetEmbedding: number; orphanedVector: number } {
  let resetEmbedding = 0;
  let orphanedVector = 0;

  try {
    // Step 1: insights claiming has_embedding=1 but no live memory_insights row
    resetEmbedding = db
      .prepare(
        `UPDATE insights SET has_embedding = 0
       WHERE has_embedding = 1
       AND id NOT IN (SELECT id FROM memory_insights WHERE deleted_at IS NULL)`,
      )
      .run().changes;

    // Step 2: orphaned memory_insights rows with no matching insights row
    orphanedVector = db
      .prepare(
        `UPDATE memory_insights SET deleted_at = datetime('now')
       WHERE deleted_at IS NULL
       AND id NOT IN (SELECT id FROM insights)`,
      )
      .run().changes;
  } catch (err: unknown) {
    // memory_insights table does not exist (sqlite-vec never loaded) — skip
    const msg = err instanceof Error ? err.message : String(err);
    if (msg.includes('no such table')) {
      return { resetEmbedding: 0, orphanedVector: 0 };
    }
    throw err; // re-throw unexpected errors
  }

  if (resetEmbedding > 0 || orphanedVector > 0) {
    log?.info('Insight reconciliation', { resetEmbedding, orphanedVector });
  }

  return { resetEmbedding, orphanedVector };
}

/**
 * Backfill parent links for subagent sessions that have no parent set.
 * Parses the file_path to extract the parent session ID from the directory structure.
 * Subagent sessions stay tier='skip' — they are accessed through their parent.
 */
export function backfillParentLinks(db: BetterSqlite3.Database): {
  linked: number;
} {
  let linked = 0;

  // Pass 1: Link subagent sessions to parent via path parsing
  const candidates = db
    .prepare(
      `
    SELECT id, file_path FROM sessions
    WHERE agent_role = 'subagent'
      AND parent_session_id IS NULL
      AND (link_source IS NULL OR link_source != 'manual')
    LIMIT 500
  `,
    )
    .all() as { id: string; file_path: string }[];

  for (const { id, file_path } of candidates) {
    const match = file_path.match(/\/([^/]+)\/subagents\/[^/]+\.jsonl$/);
    if (!match) continue;

    const parentId = match[1];
    const validation = validateParentLink(db, id, parentId);
    if (validation !== 'ok') continue;

    setParentSession(db, id, parentId, 'path');
    linked++;
  }

  return { linked };
}

/**
 * Downgrade subagent sessions that were incorrectly upgraded to 'lite' back to 'skip'.
 * Also removes orphaned FTS entries for subagent sessions.
 * Subagent content is accessed through the parent session, not independently.
 */
export function downgradeSubagentTiers(db: BetterSqlite3.Database): number {
  const downgraded = db
    .prepare(
      `
    UPDATE sessions SET tier = 'skip'
    WHERE agent_role = 'subagent' AND tier != 'skip'
  `,
    )
    .run().changes;

  // Clean up FTS entries for subagent sessions — they shouldn't be in search results
  db.prepare(
    `DELETE FROM sessions_fts WHERE session_id IN (SELECT id FROM sessions WHERE agent_role = 'subagent')`,
  ).run();

  return downgraded;
}

/**
 * Backfill empty file_path from source_locator.
 * Swift reads file_path directly for message parsing. When file_path is empty
 * but source_locator has the correct path, sessions show "No Messages" in the app.
 */
export function backfillFilePaths(db: BetterSqlite3.Database): number {
  const sessionPaths = db
    .prepare(
      `
    UPDATE sessions SET file_path = source_locator
    WHERE (file_path IS NULL OR file_path = '')
      AND source_locator IS NOT NULL
      AND source_locator != ''
      AND source_locator NOT LIKE 'sync://%'
  `,
    )
    .run().changes;

  const localPaths = db
    .prepare(
      `
    UPDATE session_local_state
    SET local_readable_path = (
      SELECT COALESCE(
        NULLIF(CASE WHEN source_locator LIKE 'sync://%' THEN '' ELSE source_locator END, ''),
        NULLIF(CASE WHEN file_path LIKE 'sync://%' THEN '' ELSE file_path END, '')
      )
      FROM sessions
      WHERE id = session_local_state.session_id
    )
    WHERE (local_readable_path IS NULL OR local_readable_path = '')
      AND EXISTS (
        SELECT 1
        FROM sessions
        WHERE id = session_local_state.session_id
          AND COALESCE(
            NULLIF(CASE WHEN source_locator LIKE 'sync://%' THEN '' ELSE source_locator END, ''),
            NULLIF(CASE WHEN file_path LIKE 'sync://%' THEN '' ELSE file_path END, '')
          ) IS NOT NULL
      )
  `,
    )
    .run().changes;

  return sessionPaths + localPaths;
}

/**
 * Backfill suggested parent links using content heuristics.
 * Scans gemini-cli and codex sessions whose first message matches a dispatch pattern
 * (e.g. `<task>`, "Your task is to...") and scores overlapping claude-code sessions
 * to find the most likely parent.
 */
/**
 * Retroactively read Codex session files to extract the `originator` field
 * from session_meta. Sessions with `originator: "Claude Code"` get
 * `agent_role = 'dispatched'` and their `link_checked_at` is cleared so
 * `backfillSuggestedParents()` can score them for a parent.
 */
export function backfillCodexOriginator(db: BetterSqlite3.Database): number {
  const candidates = db
    .prepare(
      `
    SELECT id, file_path FROM sessions
    WHERE source = 'codex'
      AND agent_role IS NULL
      AND parent_session_id IS NULL
      AND suggested_parent_id IS NULL
      AND (link_source IS NULL OR link_source != 'manual')
    LIMIT 500
  `,
    )
    .all() as { id: string; file_path: string }[];

  let updated = 0;
  const update = db.prepare(
    `UPDATE sessions SET agent_role = 'dispatched', tier = 'skip', link_checked_at = NULL WHERE id = ?`,
  );

  for (const { id, file_path } of candidates) {
    try {
      // Read the first ~16KB (session_meta line) — some Codex files have 13KB+ first lines
      const fd = openSync(file_path, 'r');
      const chunk = Buffer.alloc(16384);
      const bytesRead = readSync(fd, chunk, 0, 16384, 0);
      closeSync(fd);
      const text = chunk.toString('utf8', 0, bytesRead);
      const newlineIdx = text.indexOf('\n');
      const firstLine = newlineIdx > 0 ? text.slice(0, newlineIdx) : text;
      const obj = JSON.parse(firstLine);
      const originator = obj?.payload?.originator;
      if (originator === 'Claude Code') {
        update.run(id);
        updated++;
      }
    } catch {
      // File missing or unparseable — skip silently
    }
  }

  return updated;
}

export function backfillSuggestedParents(db: BetterSqlite3.Database): {
  checked: number;
  suggested: number;
} {
  let checked = 0;
  let suggested = 0;

  // Select agent_role so we can skip dispatch-pattern check for known agents
  const candidates = db
    .prepare(
      `
    SELECT id, start_time, project, cwd, summary, agent_role FROM sessions
    WHERE parent_session_id IS NULL
      AND suggested_parent_id IS NULL
      AND link_checked_at IS NULL
      AND link_source IS NULL
      AND source IN ('gemini-cli', 'codex')
    LIMIT 500
  `,
    )
    .all() as {
    id: string;
    start_time: string;
    project: string | null;
    cwd: string;
    summary: string | null;
    agent_role: string | null;
  }[];

  const markChecked = db.prepare(
    `UPDATE sessions SET link_checked_at = datetime('now') WHERE id = ?`,
  );

  for (const candidate of candidates) {
    checked++;

    // Sessions with a known agent_role (dispatched, worker, explorer, etc.)
    // are already confirmed agents — skip dispatch-pattern gating.
    const knownAgent = candidate.agent_role != null;
    if (!knownAgent) {
      if (!candidate.summary || !isDispatchPattern(candidate.summary)) {
        markChecked.run(candidate.id);
        continue;
      }
    }

    const parents = db
      .prepare(
        `
      SELECT id, start_time, end_time, project, cwd FROM sessions
      WHERE source IN ('claude-code', 'claude')
        AND start_time <= ?
        AND start_time >= datetime(?, '-24 hours')
        AND parent_session_id IS NULL
    `,
      )
      .all(candidate.start_time, candidate.start_time) as {
      id: string;
      start_time: string;
      end_time: string | null;
      project: string | null;
      cwd: string;
    }[];

    const scored = parents.map((p) => ({
      parentId: p.id,
      score: scoreCandidate(
        candidate.start_time,
        p.start_time,
        p.end_time,
        candidate.project,
        p.project,
        candidate.cwd,
        p.cwd,
      ),
    }));

    const bestParent = pickBestCandidate(scored);
    if (bestParent) {
      setSuggestedParent(db, candidate.id, bestParent);
      suggested++;
    } else {
      // No parent found, but dispatch pattern matched → mark as agent anyway.
      // COALESCE preserves existing roles (worker, explorer) while setting
      // 'dispatched' for sessions that have no role yet.
      db.prepare(
        `UPDATE sessions SET agent_role = COALESCE(agent_role, 'dispatched'), tier = 'skip', link_checked_at = datetime('now') WHERE id = ?`,
      ).run(candidate.id);
    }
  }

  return { checked, suggested };
}

/**
 * Reset `link_checked_at` for sessions checked by an older detection algorithm.
 * This allows `backfillSuggestedParents()` to re-evaluate them with improved logic.
 * User-confirmed/dismissed links (`link_source = 'manual'`) are never touched.
 */
export function resetStaleDetections(db: BetterSqlite3.Database): number {
  const row = db
    .prepare("SELECT value FROM metadata WHERE key = 'detection_version'")
    .get() as { value: string } | undefined;
  const storedVersion = row ? Number.parseInt(row.value, 10) : 0;

  if (storedVersion >= DETECTION_VERSION) return 0;

  // Reset sessions that were checked but didn't get a parent link
  const r1 = db
    .prepare(
      `
    UPDATE sessions
    SET link_checked_at = NULL
    WHERE link_checked_at IS NOT NULL
      AND parent_session_id IS NULL
      AND suggested_parent_id IS NULL
      AND (link_source IS NULL OR link_source != 'manual')
      AND source IN ('gemini-cli', 'codex')
  `,
    )
    .run();

  // Also reset sessions marked 'dispatched' (by old heuristic) with no parent found.
  // The improved scoring may now find a parent for them.
  const r2 = db
    .prepare(
      `
    UPDATE sessions
    SET link_checked_at = NULL
    WHERE link_checked_at IS NOT NULL
      AND agent_role = 'dispatched'
      AND parent_session_id IS NULL
      AND suggested_parent_id IS NULL
      AND (link_source IS NULL OR link_source != 'manual')
  `,
    )
    .run();

  // Store updated version
  db.prepare(
    "INSERT INTO metadata (key, value) VALUES ('detection_version', ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
  ).run(String(DETECTION_VERSION));

  return r1.changes + r2.changes;
}

export interface OrphanScanAdapter {
  readonly name: string;
  isAccessible(locator: string): Promise<boolean>;
}

export interface OrphanScanResult {
  scanned: number;
  newlyFlagged: number;
  confirmed: number;
  recovered: number;
  skipped: number;
}

/**
 * Walk every session with a locator, ask its adapter `isAccessible`, and maintain
 * the `orphan_status` / `orphan_since` / `orphan_reason` triple.
 *
 * State machine (current → next):
 *  - NULL + accessible → NULL (no-op)
 *  - NULL + unreachable → 'suspect' + orphan_since = now + reason = 'path_unreachable'
 *  - 'suspect' + accessible → cleared (file came back — rename/mount restored)
 *  - 'suspect' + unreachable + age ≥ 30d → promote to 'confirmed'
 *  - 'confirmed' + accessible → cleared (very late recovery)
 *  - 'confirmed' + unreachable → no-op (ready for GC later)
 *
 * Caller should run this as a background task (not on a blocking path).
 */
export async function detectOrphans(
  db: BetterSqlite3.Database,
  adapters: readonly OrphanScanAdapter[],
  opts: { gracePeriodDays?: number } = {},
): Promise<OrphanScanResult> {
  const gracePeriodDays = opts.gracePeriodDays ?? 30;
  const adapterByName = new Map<string, OrphanScanAdapter>();
  for (const a of adapters) adapterByName.set(a.name, a);

  const rows = db
    .prepare(
      `
    SELECT id, source, file_path, source_locator, orphan_status, orphan_since
    FROM sessions
    WHERE (source_locator IS NOT NULL AND source_locator != '')
       OR (file_path IS NOT NULL AND file_path != '')
  `,
    )
    .all() as {
    id: string;
    source: string;
    file_path: string | null;
    source_locator: string | null;
    orphan_status: string | null;
    orphan_since: string | null;
  }[];

  const markSuspect = db.prepare(`
    UPDATE sessions
    SET orphan_status = 'suspect',
        orphan_since = datetime('now'),
        orphan_reason = COALESCE(orphan_reason, 'path_unreachable')
    WHERE id = ?
  `);
  const promoteConfirmed = db.prepare(
    `UPDATE sessions SET orphan_status = 'confirmed' WHERE id = ?`,
  );
  const clearFlag = db.prepare(`
    UPDATE sessions
    SET orphan_status = NULL, orphan_since = NULL, orphan_reason = NULL
    WHERE id = ?
  `);

  let scanned = 0;
  let newlyFlagged = 0;
  let confirmed = 0;
  let recovered = 0;
  let skipped = 0;
  const now = Date.now();
  const graceMs = gracePeriodDays * 24 * 60 * 60 * 1000;

  for (const row of rows) {
    scanned++;
    const adapter = adapterByName.get(row.source);
    const locator = row.file_path || row.source_locator || '';
    if (!adapter || !locator) {
      skipped++;
      continue;
    }
    // Skip sync-only locators — remote rows are not our problem
    if (locator.startsWith('sync://')) {
      skipped++;
      continue;
    }

    let accessible = false;
    try {
      accessible = await adapter.isAccessible(locator);
    } catch {
      accessible = false;
    }

    if (accessible) {
      if (row.orphan_status !== null) {
        clearFlag.run(row.id);
        recovered++;
      }
      continue;
    }

    if (row.orphan_status === null) {
      markSuspect.run(row.id);
      newlyFlagged++;
      continue;
    }

    if (row.orphan_status === 'suspect' && row.orphan_since) {
      const sinceMs = Date.parse(`${row.orphan_since}Z`);
      if (!Number.isNaN(sinceMs) && now - sinceMs >= graceMs) {
        promoteConfirmed.run(row.id);
        confirmed++;
      }
    }
  }

  return { scanned, newlyFlagged, confirmed, recovered, skipped };
}

/**
 * Mark a single session as orphan (used by the watcher unlink handler).
 * Does NOT promote confirmed; that only happens via the periodic detectOrphans pass.
 */
export function markSessionOrphan(
  db: BetterSqlite3.Database,
  sessionId: string,
  reason: 'cleaned_by_source' | 'file_deleted' | 'path_unreachable',
): void {
  db.prepare(
    `
    UPDATE sessions
    SET orphan_status = COALESCE(orphan_status, 'suspect'),
        orphan_since = COALESCE(orphan_since, datetime('now')),
        orphan_reason = COALESCE(orphan_reason, ?)
    WHERE id = ?
  `,
  ).run(reason, sessionId);
}

/**
 * Called by the watcher when a session file is unlinked. Marks every row whose
 * locator matches as orphan. Returns the number of rows touched.
 */
export function markOrphanByPath(
  db: BetterSqlite3.Database,
  filePath: string,
  reason: 'cleaned_by_source' | 'file_deleted' = 'cleaned_by_source',
): number {
  if (!filePath) return 0;
  return db
    .prepare(
      `
    UPDATE sessions
    SET orphan_status = COALESCE(orphan_status, 'suspect'),
        orphan_since = COALESCE(orphan_since, datetime('now')),
        orphan_reason = COALESCE(orphan_reason, ?)
    WHERE file_path = ? OR source_locator = ?
  `,
    )
    .run(reason, filePath, filePath).changes;
}

export interface ApplyMigrationInput {
  migrationId: string;
  oldPath: string;
  newPath: string;
  oldBasename: string;
  newBasename: string;
}

export interface ApplyMigrationResult {
  sessionsUpdated: number;
  localStateUpdated: number;
  aliasCreated: boolean;
}

/**
 * Phase C of the project-move pipeline. Runs in a single DB transaction.
 * Caller must have already:
 *   1. Inserted migration_log row with state='fs_pending' (startMigration)
 *   2. Completed all FS operations (mv, JSONL patch, CC dir rename)
 *   3. Marked state='fs_done' (markFsDone)
 *
 * This function:
 *   - UPDATEs sessions' source_locator / file_path / cwd with strict '/' boundary
 *     (so '/foo/bar' does NOT match '/foo/barbar')
 *   - UPDATEs session_local_state.local_readable_path (UI reads this first!)
 *   - Adds project_aliases row when basenames differ
 *   - Clears orphan_* flags on matched rows (file existed before move,
 *     now points to the new location — not an orphan anymore)
 *   - Marks migration_log state='committed'
 *
 * Idempotent: running twice with the same old/new is a no-op on the second call
 * (no rows match old paths anymore).
 */
export function applyMigrationDb(
  db: BetterSqlite3.Database,
  input: ApplyMigrationInput,
): ApplyMigrationResult {
  const { migrationId, oldPath, newPath, oldBasename, newBasename } = input;

  // Committed early-exit (Codex #2): if this migration has already been
  // successfully committed, return the cached counts instead of re-running
  // the transaction. Otherwise a retry would overwrite sessions_updated=0
  // (since no rows match the old path anymore).
  const existing = db
    .prepare(
      'SELECT state, sessions_updated, alias_created FROM migration_log WHERE id = ?',
    )
    .get(migrationId) as
    | { state: string; sessions_updated: number; alias_created: number }
    | undefined;
  if (existing?.state === 'committed') {
    return {
      sessionsUpdated: existing.sessions_updated,
      localStateUpdated: 0, // not tracked in log, and irrelevant on replay
      aliasCreated: Boolean(existing.alias_created),
    };
  }

  // Use substr prefix comparison to avoid LIKE wildcard hazards.
  // A column value "belongs to oldPath" iff:
  //   value = oldPath              (exact match)
  //   OR length(value) > length(oldPath)
  //      AND substr(value, 1, length(oldPath)+1) = oldPath || '/'   (subtree)
  // This matches mvp.py's path-rewrite semantics but is safe for paths
  // containing `_` or `%` which LIKE would treat as wildcards.
  const pathMatch = (col: string) =>
    `(${col} = @old OR (LENGTH(${col}) > LENGTH(@old) AND SUBSTR(${col}, 1, LENGTH(@old) + 1) = @old || '/'))`;
  const rewrite = (col: string) =>
    `CASE
       WHEN ${col} = @old THEN @new
       WHEN LENGTH(${col}) > LENGTH(@old)
            AND SUBSTR(${col}, 1, LENGTH(@old) + 1) = @old || '/'
         THEN @new || SUBSTR(${col}, LENGTH(@old) + 1)
       ELSE ${col}
     END`;

  // Run all writes + the commit log entry inside one transaction
  const tx = db.transaction((): ApplyMigrationResult => {
    // 1a. Collect affected session ids BEFORE the UPDATE — Phase 3 undo
    // needs the authoritative list, not a prefix-reverse guess. Stored in
    // migration_log.detail.
    const affectedRows = db
      .prepare(
        `
      SELECT id FROM sessions
       WHERE ${pathMatch('source_locator')}
          OR ${pathMatch('file_path')}
          OR ${pathMatch('cwd')}
    `,
      )
      .all({ old: oldPath }) as { id: string }[];
    const affectedSessionIds = affectedRows.map((r) => r.id);

    // 1b. Rewrite sessions path fields for matched rows.
    // NOTE: we deliberately do NOT clear orphan_* flags here. "Filesystem
    // is the only truth" — detectOrphans decides orphan state based on
    // actual isAccessible(), not on path rewrites. If a session was a
    // stale zombie pointing at a deleted subagent file, moving the DB path
    // doesn't un-ghost it.
    const sessionsRes = db
      .prepare(
        `
      UPDATE sessions
         SET source_locator = ${rewrite('source_locator')},
             file_path      = ${rewrite('file_path')},
             cwd            = ${rewrite('cwd')}
       WHERE ${pathMatch('source_locator')}
          OR ${pathMatch('file_path')}
          OR ${pathMatch('cwd')}
    `,
      )
      .run({ old: oldPath, new: newPath });

    // 2. Rewrite session_local_state.local_readable_path (UI read-priority field)
    const localRes = db
      .prepare(
        `
      UPDATE session_local_state
         SET local_readable_path = ${rewrite('local_readable_path')}
       WHERE ${pathMatch('local_readable_path')}
    `,
      )
      .run({ old: oldPath, new: newPath });

    // 3. Add project alias iff basenames differ (idempotent via INSERT OR IGNORE)
    let aliasCreated = false;
    if (oldBasename !== newBasename && oldBasename && newBasename) {
      const before = db
        .prepare(
          'SELECT COUNT(*) AS c FROM project_aliases WHERE alias = ? AND canonical = ?',
        )
        .get(oldBasename, newBasename) as { c: number };
      addProjectAlias(db, oldBasename, newBasename);
      const after = db
        .prepare(
          'SELECT COUNT(*) AS c FROM project_aliases WHERE alias = ? AND canonical = ?',
        )
        .get(oldBasename, newBasename) as { c: number };
      aliasCreated = after.c > before.c;
    }

    // 4. Merge affected session ids into migration_log.detail.
    // The row may already have a detail payload from Phase B (markFsDone);
    // we don't want to lose that, so read-merge-write.
    const existingDetail = db
      .prepare('SELECT detail FROM migration_log WHERE id = ?')
      .get(migrationId) as { detail: string | null } | undefined;
    const merged = {
      ...(existingDetail?.detail
        ? (JSON.parse(existingDetail.detail) as Record<string, unknown>)
        : {}),
      affectedSessionIds,
    };
    db.prepare('UPDATE migration_log SET detail = ? WHERE id = ?').run(
      JSON.stringify(merged),
      migrationId,
    );

    // 5. Mark migration_log state='committed'
    finishMigration(db, {
      id: migrationId,
      sessionsUpdated: sessionsRes.changes,
      aliasCreated,
    });

    return {
      sessionsUpdated: sessionsRes.changes,
      localStateUpdated: localRes.changes,
      aliasCreated,
    };
  });

  return tx();
}
