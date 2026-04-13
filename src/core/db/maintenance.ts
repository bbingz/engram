// src/core/db/maintenance.ts — post-migration backfills and DB maintenance
import type BetterSqlite3 from 'better-sqlite3';
import {
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
 * Also upgrades tier from 'skip' to 'lite' for any linked sessions.
 */
export function backfillParentLinks(db: BetterSqlite3.Database): {
  linked: number;
  tierUpgraded: number;
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

  // Tier upgrade pass
  const tierUpgraded = db
    .prepare(
      `
    UPDATE sessions SET tier = 'lite'
    WHERE parent_session_id IS NOT NULL AND tier = 'skip'
  `,
    )
    .run().changes;

  return { linked, tierUpgraded };
}

/**
 * Backfill suggested parent links using content heuristics.
 * Scans gemini-cli and codex sessions whose first message matches a dispatch pattern
 * (e.g. `<task>`, "Your task is to...") and scores overlapping claude-code sessions
 * to find the most likely parent.
 */
export function backfillSuggestedParents(db: BetterSqlite3.Database): {
  checked: number;
  suggested: number;
} {
  let checked = 0;
  let suggested = 0;

  const candidates = db
    .prepare(
      `
    SELECT id, start_time, project, cwd, summary FROM sessions
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
  }[];

  const markChecked = db.prepare(
    `UPDATE sessions SET link_checked_at = datetime('now') WHERE id = ?`,
  );

  for (const candidate of candidates) {
    checked++;
    if (!candidate.summary || !isDispatchPattern(candidate.summary)) {
      markChecked.run(candidate.id);
      continue;
    }

    const parents = db
      .prepare(
        `
      SELECT id, start_time, end_time, project FROM sessions
      WHERE source IN ('claude-code', 'claude')
        AND start_time <= ?
        AND (end_time IS NULL OR end_time >= ?)
        AND parent_session_id IS NULL
        AND hidden_at IS NULL
    `,
      )
      .all(candidate.start_time, candidate.start_time) as {
      id: string;
      start_time: string;
      end_time: string | null;
      project: string | null;
    }[];

    const scored = parents.map((p) => ({
      parentId: p.id,
      score: scoreCandidate(
        candidate.start_time,
        p.start_time,
        p.end_time,
        candidate.project,
        p.project,
      ),
    }));

    const bestParent = pickBestCandidate(scored);
    if (bestParent) {
      setSuggestedParent(db, candidate.id, bestParent);
      suggested++;
    } else {
      markChecked.run(candidate.id);
    }
  }

  return { checked, suggested };
}
