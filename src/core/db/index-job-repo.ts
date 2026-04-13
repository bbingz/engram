// src/core/db/index-job-repo.ts — index job queue management
import type BetterSqlite3 from 'better-sqlite3';
import type {
  IndexJobKind,
  IndexJobStatus,
  PersistedIndexJob,
} from '../session-snapshot.js';

function buildIndexJobId(
  sessionId: string,
  targetSyncVersion: number,
  jobKind: IndexJobKind,
): string {
  return `${sessionId}:${targetSyncVersion}:${jobKind}`;
}

export function insertIndexJobs(
  db: BetterSqlite3.Database,
  sessionId: string,
  targetSyncVersion: number,
  jobKinds: IndexJobKind[],
): void {
  const insert = db.prepare(`
    INSERT INTO session_index_jobs (
      id, session_id, job_kind, target_sync_version, status, retry_count, last_error, created_at, updated_at
    ) VALUES (
      @id, @sessionId, @jobKind, @targetSyncVersion, 'pending', 0, NULL, datetime('now'), datetime('now')
    )
    ON CONFLICT(id) DO UPDATE SET
      status = 'pending',
      last_error = NULL,
      updated_at = datetime('now')
  `);
  const tx = db.transaction((kinds: IndexJobKind[]) => {
    for (const jobKind of kinds) {
      insert.run({
        id: buildIndexJobId(sessionId, targetSyncVersion, jobKind),
        sessionId,
        jobKind,
        targetSyncVersion,
      });
    }
  });
  tx(jobKinds);
}

export function takeRecoverableIndexJobs(
  db: BetterSqlite3.Database,
  limit: number,
): PersistedIndexJob[] {
  const rows = db
    .prepare(`
    SELECT id, session_id, job_kind, target_sync_version, status, retry_count, last_error, created_at, updated_at
    FROM session_index_jobs
    WHERE status IN ('pending', 'failed_retryable')
    ORDER BY CASE job_kind WHEN 'fts' THEN 0 ELSE 1 END, created_at, id
    LIMIT @limit
  `)
    .all({ limit }) as Array<{
    id: string;
    session_id: string;
    job_kind: IndexJobKind;
    target_sync_version: number;
    status: IndexJobStatus;
    retry_count: number;
    last_error: string | null;
    created_at: string;
    updated_at: string;
  }>;
  return rows.map((row) => ({
    id: row.id,
    sessionId: row.session_id,
    jobKind: row.job_kind,
    targetSyncVersion: row.target_sync_version,
    status: row.status,
    retryCount: row.retry_count,
    lastError: row.last_error ?? undefined,
    createdAt: row.created_at,
    updatedAt: row.updated_at,
  }));
}

export function listIndexJobs(
  db: BetterSqlite3.Database,
  sessionId: string,
): PersistedIndexJob[] {
  const rows = db
    .prepare(`
    SELECT id, session_id, job_kind, target_sync_version, status, retry_count, last_error, created_at, updated_at
    FROM session_index_jobs
    WHERE session_id = ?
    ORDER BY created_at, id
  `)
    .all(sessionId) as Array<{
    id: string;
    session_id: string;
    job_kind: IndexJobKind;
    target_sync_version: number;
    status: IndexJobStatus;
    retry_count: number;
    last_error: string | null;
    created_at: string;
    updated_at: string;
  }>;
  return rows.map((row) => ({
    id: row.id,
    sessionId: row.session_id,
    jobKind: row.job_kind,
    targetSyncVersion: row.target_sync_version,
    status: row.status,
    retryCount: row.retry_count,
    lastError: row.last_error ?? undefined,
    createdAt: row.created_at,
    updatedAt: row.updated_at,
  }));
}

export function markIndexJobCompleted(
  db: BetterSqlite3.Database,
  id: string,
): void {
  db.prepare(`
    UPDATE session_index_jobs
    SET status = 'completed', last_error = NULL, updated_at = datetime('now')
    WHERE id = ?
  `).run(id);
}

export function markIndexJobNotApplicable(
  db: BetterSqlite3.Database,
  id: string,
): void {
  db.prepare(`
    UPDATE session_index_jobs
    SET status = 'not_applicable', last_error = NULL, updated_at = datetime('now')
    WHERE id = ?
  `).run(id);
}

export function markIndexJobRetryableFailure(
  db: BetterSqlite3.Database,
  id: string,
  error: string,
): void {
  db.prepare(`
    UPDATE session_index_jobs
    SET status = 'failed_retryable',
        retry_count = retry_count + 1,
        last_error = ?,
        updated_at = datetime('now')
    WHERE id = ?
  `).run(error, id);
}
