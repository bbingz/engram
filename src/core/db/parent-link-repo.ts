// src/core/db/parent-link-repo.ts — parent/child session link management
import type BetterSqlite3 from 'better-sqlite3';
import type { SessionInfo } from '../../adapters/types.js';
import { pickReadableSessionPath } from '../session-path.js';

type LinkValidation =
  | 'ok'
  | 'self-link'
  | 'parent-not-found'
  | 'depth-exceeded';

/**
 * Validate whether a parent link is allowed.
 * - self-link: sessionId === parentId
 * - parent-not-found: parent session doesn't exist
 * - depth-exceeded: parent already has its own parent (max depth = 1)
 */
export function validateParentLink(
  db: BetterSqlite3.Database,
  sessionId: string,
  parentId: string,
): LinkValidation {
  if (sessionId === parentId) return 'self-link';

  const parent = db
    .prepare('SELECT id, parent_session_id FROM sessions WHERE id = ?')
    .get(parentId) as
    | { id: string; parent_session_id: string | null }
    | undefined;

  if (!parent) return 'parent-not-found';
  if (parent.parent_session_id) return 'depth-exceeded';

  return 'ok';
}

/**
 * Set confirmed parent on a session. Clears any existing suggestion.
 * Tier is not modified — subagent sessions stay 'skip'.
 */
export function setParentSession(
  db: BetterSqlite3.Database,
  sessionId: string,
  parentId: string,
  linkSource: 'path' | 'manual',
): void {
  db.prepare(`
    UPDATE sessions
    SET parent_session_id = @parentId,
        link_source = @linkSource,
        suggested_parent_id = NULL
    WHERE id = @sessionId
  `).run({ sessionId, parentId, linkSource });
}

/**
 * Clear the confirmed parent. Sets link_source='manual' to prevent
 * auto-detection from re-linking, and resets tier to NULL.
 */
export function clearParentSession(
  db: BetterSqlite3.Database,
  sessionId: string,
): void {
  db.prepare(`
    UPDATE sessions
    SET parent_session_id = NULL,
        link_source = 'manual',
        tier = NULL
    WHERE id = @sessionId
  `).run({ sessionId });
}

/**
 * Set a suggested (unconfirmed) parent for a session.
 * Also stamps link_checked_at.
 */
export function setSuggestedParent(
  db: BetterSqlite3.Database,
  sessionId: string,
  suggestedParentId: string,
): void {
  db.prepare(`
    UPDATE sessions
    SET suggested_parent_id = @suggestedParentId,
        link_checked_at = datetime('now')
    WHERE id = @sessionId
  `).run({ sessionId, suggestedParentId });
}

/**
 * Conditionally clear suggested parent — only if it matches expectedParentId.
 * Returns true if the update was applied.
 */
export function clearSuggestedParent(
  db: BetterSqlite3.Database,
  sessionId: string,
  expectedParentId: string,
): boolean {
  const result = db
    .prepare(`
      UPDATE sessions
      SET suggested_parent_id = NULL, link_checked_at = datetime('now')
      WHERE id = @sessionId AND suggested_parent_id = @expectedParentId
    `)
    .run({ sessionId, expectedParentId });
  return result.changes > 0;
}

/**
 * Promote a suggested parent to a confirmed parent.
 * Validates the link before promoting.
 */
export function confirmSuggestion(
  db: BetterSqlite3.Database,
  sessionId: string,
): { ok: boolean; error?: string } {
  const row = db
    .prepare('SELECT suggested_parent_id FROM sessions WHERE id = ?')
    .get(sessionId) as { suggested_parent_id: string | null } | undefined;

  if (!row?.suggested_parent_id) {
    return { ok: false, error: 'no suggestion exists for this session' };
  }

  const suggestedParentId = row.suggested_parent_id;
  const validation = validateParentLink(db, sessionId, suggestedParentId);
  if (validation !== 'ok') {
    return { ok: false, error: validation };
  }

  setParentSession(db, sessionId, suggestedParentId, 'manual');
  return { ok: true };
}

// ── Query helpers ──────────────────────────────────────────────

function rowToSessionInfo(row: Record<string, unknown>): SessionInfo {
  return {
    id: row.id as string,
    source: row.source as SessionInfo['source'],
    startTime: row.start_time as string,
    endTime: row.end_time as string | undefined,
    cwd: row.cwd as string,
    project: row.project as string | undefined,
    model: row.model as string | undefined,
    messageCount: row.message_count as number,
    userMessageCount: row.user_message_count as number,
    assistantMessageCount: (row.assistant_message_count as number) ?? 0,
    toolMessageCount: (row.tool_message_count as number) ?? 0,
    systemMessageCount: (row.system_message_count as number) ?? 0,
    summary: row.summary as string | undefined,
    filePath: pickReadableSessionPath(
      row.file_path as string | undefined,
      row.source_locator as string | undefined,
    ),
    sizeBytes: row.size_bytes as number,
    indexedAt: row.indexed_at as string | undefined,
    agentRole: row.agent_role as string | undefined,
    origin: row.origin as string | undefined,
    summaryMessageCount: row.summary_message_count as number | undefined,
    tier: row.tier as string | undefined,
    qualityScore: (row.quality_score as number | null) ?? 0,
    parentSessionId: row.parent_session_id as string | undefined,
    suggestedParentId: row.suggested_parent_id as string | undefined,
  };
}

/**
 * List confirmed child sessions of a parent, sorted by start_time ASC.
 */
export function childSessions(
  db: BetterSqlite3.Database,
  parentId: string,
  limit: number,
  offset: number,
): SessionInfo[] {
  const rows = db
    .prepare(`
      SELECT * FROM sessions
      WHERE parent_session_id = @parentId
      ORDER BY start_time ASC
      LIMIT @limit OFFSET @offset
    `)
    .all({ parentId, limit, offset }) as Record<string, unknown>[];
  return rows.map(rowToSessionInfo);
}

/**
 * Batch count confirmed children for multiple parent IDs.
 */
export function childCount(
  db: BetterSqlite3.Database,
  parentIds: string[],
): Map<string, number> {
  const result = new Map<string, number>();
  if (parentIds.length === 0) return result;

  // Initialize all to 0
  for (const id of parentIds) {
    result.set(id, 0);
  }

  const placeholders = parentIds.map((_, i) => `@p${i}`).join(',');
  const params: Record<string, string> = {};
  for (let i = 0; i < parentIds.length; i++) {
    params[`p${i}`] = parentIds[i];
  }

  const rows = db
    .prepare(
      `SELECT parent_session_id, COUNT(*) as cnt
       FROM sessions
       WHERE parent_session_id IN (${placeholders})
       GROUP BY parent_session_id`,
    )
    .all(params) as { parent_session_id: string; cnt: number }[];

  for (const row of rows) {
    result.set(row.parent_session_id, row.cnt);
  }

  return result;
}

/**
 * List sessions with a suggested (unconfirmed) parent link.
 */
export function suggestedChildSessions(
  db: BetterSqlite3.Database,
  parentId: string,
): SessionInfo[] {
  const rows = db
    .prepare(`
      SELECT * FROM sessions
      WHERE suggested_parent_id = @parentId
      ORDER BY start_time ASC
    `)
    .all({ parentId }) as Record<string, unknown>[];
  return rows.map(rowToSessionInfo);
}

/**
 * Batch count suggested children for multiple parent IDs.
 */
export function suggestedChildCount(
  db: BetterSqlite3.Database,
  parentIds: string[],
): Map<string, number> {
  const result = new Map<string, number>();
  if (parentIds.length === 0) return result;

  for (const id of parentIds) {
    result.set(id, 0);
  }

  const placeholders = parentIds.map((_, i) => `@p${i}`).join(',');
  const params: Record<string, string> = {};
  for (let i = 0; i < parentIds.length; i++) {
    params[`p${i}`] = parentIds[i];
  }

  const rows = db
    .prepare(
      `SELECT suggested_parent_id, COUNT(*) as cnt
       FROM sessions
       WHERE suggested_parent_id IN (${placeholders})
       GROUP BY suggested_parent_id`,
    )
    .all(params) as { suggested_parent_id: string; cnt: number }[];

  for (const row of rows) {
    result.set(row.suggested_parent_id, row.cnt);
  }

  return result;
}
