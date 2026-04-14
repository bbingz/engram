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
