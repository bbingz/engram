// src/core/db/sync-repo.ts — sync state and local state management
import type BetterSqlite3 from 'better-sqlite3';
import type { SessionLocalState, SyncCursor } from '../session-snapshot.js';

export function getSyncTime(
  db: BetterSqlite3.Database,
  peerName: string,
): string | null {
  const row = db
    .prepare('SELECT last_sync_time FROM sync_state WHERE peer_name = ?')
    .get(peerName) as { last_sync_time: string } | undefined;
  return row?.last_sync_time ?? null;
}

export function setSyncTime(
  db: BetterSqlite3.Database,
  peerName: string,
  time: string,
): void {
  db.prepare(
    'INSERT INTO sync_state (peer_name, last_sync_time, last_sync_session_id) VALUES (?, ?, ?) ON CONFLICT(peer_name) DO UPDATE SET last_sync_time = excluded.last_sync_time',
  ).run(peerName, time, null);
}

export function getSyncCursor(
  db: BetterSqlite3.Database,
  peerName: string,
): SyncCursor | null {
  const row = db
    .prepare(
      'SELECT last_sync_time, last_sync_session_id FROM sync_state WHERE peer_name = ?',
    )
    .get(peerName) as
    | { last_sync_time: string; last_sync_session_id: string | null }
    | undefined;
  if (!row?.last_sync_time || !row.last_sync_session_id) return null;
  return {
    indexedAt: row.last_sync_time,
    sessionId: row.last_sync_session_id,
  };
}

export function setSyncCursor(
  db: BetterSqlite3.Database,
  peerName: string,
  cursor: SyncCursor,
): void {
  db.prepare(`
    INSERT INTO sync_state (peer_name, last_sync_time, last_sync_session_id)
    VALUES (@peerName, @indexedAt, @sessionId)
    ON CONFLICT(peer_name) DO UPDATE SET
      last_sync_time = excluded.last_sync_time,
      last_sync_session_id = excluded.last_sync_session_id
  `).run({
    peerName,
    indexedAt: cursor.indexedAt,
    sessionId: cursor.sessionId,
  });
}

export function getLocalState(
  db: BetterSqlite3.Database,
  sessionId: string,
): SessionLocalState | null {
  const row = db
    .prepare(`
    SELECT session_id, hidden_at, custom_name, local_readable_path
    FROM session_local_state
    WHERE session_id = ?
  `)
    .get(sessionId) as
    | {
        session_id: string;
        hidden_at: string | null;
        custom_name: string | null;
        local_readable_path: string | null;
      }
    | undefined;
  if (!row) return null;
  return {
    sessionId: row.session_id,
    hiddenAt: row.hidden_at ?? undefined,
    customName: row.custom_name ?? undefined,
    localReadablePath: row.local_readable_path ?? undefined,
  };
}

export function setLocalReadablePath(
  db: BetterSqlite3.Database,
  sessionId: string,
  localReadablePath: string | null,
): void {
  db.prepare(`
    INSERT INTO session_local_state (session_id, local_readable_path)
    VALUES (?, ?)
    ON CONFLICT(session_id) DO UPDATE SET local_readable_path = excluded.local_readable_path
  `).run(sessionId, localReadablePath);
}
