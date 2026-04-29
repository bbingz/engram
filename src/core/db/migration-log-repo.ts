// src/core/db/migration-log-repo.ts — migration_log CRUD and pending-migration guard
//
// Three-phase write protocol (see plans/project-move-takeover.md §2.1):
//   Phase A: startMigration()     → state='fs_pending'  (BEFORE FS ops)
//   Phase B: markFsDone()         → state='fs_done'     (AFTER FS + JSONL patch)
//   Phase C: finishMigration()    → state='committed'   (in DB transaction)
//   Failure: failMigration()      → state='failed'      (any phase)
//
// Watcher guard: hasPendingMigrationFor(path) returns true if any row with
// state IN ('fs_pending','fs_done') covers the path — onUnlink uses this
// to skip marking sessions as orphans during an active migration.

import type BetterSqlite3 from 'better-sqlite3';

export type MigrationState = 'fs_pending' | 'fs_done' | 'committed' | 'failed';

export type MigrationActor = 'cli' | 'mcp' | 'swift-ui' | 'batch';

export interface MigrationLogRow {
  id: string;
  oldPath: string;
  newPath: string;
  oldBasename: string;
  newBasename: string;
  state: MigrationState;
  filesPatched: number;
  occurrences: number;
  sessionsUpdated: number;
  aliasCreated: boolean;
  ccDirRenamed: boolean;
  startedAt: string;
  finishedAt: string | null;
  dryRun: boolean;
  rolledBackOf: string | null;
  auditNote: string | null;
  archived: boolean;
  actor: MigrationActor;
  detail: Record<string, unknown> | null;
  error: string | null;
}

export interface StartMigrationInput {
  id: string;
  oldPath: string;
  newPath: string;
  oldBasename: string;
  newBasename: string;
  dryRun?: boolean;
  auditNote?: string | null;
  archived?: boolean;
  actor?: MigrationActor;
  rolledBackOf?: string | null;
}

export function startMigration(
  db: BetterSqlite3.Database,
  input: StartMigrationInput,
): void {
  if (input.oldPath === input.newPath) {
    throw new Error(
      `startMigration: oldPath and newPath are the same (${input.oldPath})`,
    );
  }
  db.prepare(
    `
    INSERT INTO migration_log (
      id, old_path, new_path, old_basename, new_basename,
      state, started_at, dry_run, audit_note, archived, actor, rolled_back_of
    )
    VALUES (
      @id, @oldPath, @newPath, @oldBasename, @newBasename,
      'fs_pending', datetime('now'), @dryRun, @auditNote, @archived, @actor, @rolledBackOf
    )
  `,
  ).run({
    id: input.id,
    oldPath: input.oldPath,
    newPath: input.newPath,
    oldBasename: input.oldBasename,
    newBasename: input.newBasename,
    dryRun: input.dryRun ? 1 : 0,
    auditNote: input.auditNote ?? null,
    archived: input.archived ? 1 : 0,
    actor: input.actor ?? 'cli',
    rolledBackOf: input.rolledBackOf ?? null,
  });
}

export interface FsDoneInput {
  id: string;
  filesPatched: number;
  occurrences: number;
  ccDirRenamed: boolean;
  detail?: Record<string, unknown>;
}

export function markFsDone(
  db: BetterSqlite3.Database,
  input: FsDoneInput,
): void {
  const res = db
    .prepare(
      `
    UPDATE migration_log
       SET state = 'fs_done',
           files_patched = @filesPatched,
           occurrences = @occurrences,
           cc_dir_renamed = @ccDirRenamed,
           detail = @detail
     WHERE id = @id AND state = 'fs_pending'
  `,
    )
    .run({
      id: input.id,
      filesPatched: input.filesPatched,
      occurrences: input.occurrences,
      ccDirRenamed: input.ccDirRenamed ? 1 : 0,
      detail: input.detail ? JSON.stringify(input.detail) : null,
    });
  if (res.changes !== 1) {
    assertMigrationTransition(db, input.id, 'fs_pending', 'markFsDone');
  }
}

export interface FinishMigrationInput {
  id: string;
  sessionsUpdated: number;
  aliasCreated: boolean;
}

/**
 * Phase C — write inside the DB transaction in applyMigrationDb(),
 * after sessions/session_local_state updates have run. Marks committed.
 */
export function finishMigration(
  db: BetterSqlite3.Database,
  input: FinishMigrationInput,
): void {
  const res = db
    .prepare(
      `
    UPDATE migration_log
       SET state = 'committed',
           sessions_updated = @sessionsUpdated,
           alias_created = @aliasCreated,
           finished_at = datetime('now')
     WHERE id = @id AND state = 'fs_done'
  `,
    )
    .run({
      id: input.id,
      sessionsUpdated: input.sessionsUpdated,
      aliasCreated: input.aliasCreated ? 1 : 0,
    });
  if (res.changes !== 1) {
    assertMigrationTransition(db, input.id, 'fs_done', 'finishMigration');
  }
}

export function failMigration(
  db: BetterSqlite3.Database,
  id: string,
  error: string,
): void {
  // failMigration is allowed from any non-terminal state (fs_pending / fs_done).
  const res = db
    .prepare(
      `
    UPDATE migration_log
       SET state = 'failed',
           error = @error,
           finished_at = datetime('now')
     WHERE id = @id AND state IN ('fs_pending', 'fs_done')
  `,
    )
    .run({ id, error: error.slice(0, 2000) });
  if (res.changes !== 1) {
    assertMigrationTransition(
      db,
      id,
      ['fs_pending', 'fs_done'],
      'failMigration',
    );
  }
}

/**
 * Throw a descriptive error when a state transition is rejected.
 * Reads the current row to distinguish "id not found" vs "wrong state".
 */
function assertMigrationTransition(
  db: BetterSqlite3.Database,
  id: string,
  expected: MigrationState | MigrationState[],
  op: string,
): never {
  const row = db
    .prepare('SELECT state FROM migration_log WHERE id = ?')
    .get(id) as { state: string } | undefined;
  if (!row) {
    throw new Error(`${op}: migration ${id} not found`);
  }
  const exp = Array.isArray(expected) ? expected.join('|') : expected;
  throw new Error(
    `${op}: migration ${id} is in state '${row.state}', expected '${exp}'`,
  );
}

export function findMigration(
  db: BetterSqlite3.Database,
  id: string,
): MigrationLogRow | null {
  const row = db.prepare('SELECT * FROM migration_log WHERE id = ?').get(id) as
    | Record<string, unknown>
    | undefined;
  return row ? rowToMigration(row) : null;
}

export interface ListMigrationsOptions {
  limit?: number;
  offset?: number;
  state?: MigrationState | MigrationState[];
  since?: string;
}

export function listMigrations(
  db: BetterSqlite3.Database,
  opts: ListMigrationsOptions = {},
): MigrationLogRow[] {
  const conditions: string[] = [];
  const params: Record<string, unknown> = {};
  if (opts.state) {
    const states = Array.isArray(opts.state) ? opts.state : [opts.state];
    const placeholders = states
      .map((s, i) => {
        params[`state${i}`] = s;
        return `@state${i}`;
      })
      .join(',');
    conditions.push(`state IN (${placeholders})`);
  }
  if (opts.since) {
    conditions.push('started_at >= @since');
    params.since = opts.since;
  }
  const where = conditions.length ? `WHERE ${conditions.join(' AND ')}` : '';
  const limit = opts.limit ?? 100;
  const offset = opts.offset ?? 0;
  // rowid DESC as tie-breaker — SQLite's datetime('now') is second-precision,
  // multiple migrations in the same second would otherwise be non-deterministic.
  const rows = db
    .prepare(
      `SELECT * FROM migration_log ${where} ORDER BY started_at DESC, rowid DESC LIMIT @limit OFFSET @offset`,
    )
    .all({ ...params, limit, offset }) as Record<string, unknown>[];
  return rows.map(rowToMigration);
}

/**
 * Watcher guard: true if any non-terminal migration covers this filesystem path.
 * Non-terminal = state IN ('fs_pending','fs_done'). Covers = path starts with
 * old_path/, or path starts with new_path/ (FS move may be in flight either way).
 *
 * Called by watcher.onUnlink before markOrphanByPath; a true here means "don't
 * mark as orphan — this unlink is part of an in-flight project move."
 */
/** TTL for a non-terminal migration to count as "pending" for the watcher
 * guard. Longer than this → assume crashed; let watcher resume normal orphan
 * marking. Daemon/MCP startup sweep (cleanupStaleMigrations) converts these
 * to state='failed' so they stop showing up in list/history.
 */
const PENDING_MIGRATION_TTL_SECONDS = 60 * 60; // 1 hour

/** Age threshold at which startup sweep flips pending rows to 'failed'. */
const STALE_MIGRATION_THRESHOLD_SECONDS = 24 * 60 * 60; // 24 hours

export function hasPendingMigrationFor(
  db: BetterSqlite3.Database,
  filePath: string,
): boolean {
  if (!filePath) return false;
  // Use substr prefix match instead of LIKE — LIKE would interpret _/%
  // in old_path as wildcards (e.g. /Users/john_doe/proj would match johnXdoe).
  // substr(@p, 1, length(old_path) + 1) = old_path || '/' is literal-safe.
  //
  // TTL: rows older than PENDING_MIGRATION_TTL_SECONDS are treated as crashed
  // and ignored — otherwise a killed process could lock the watcher forever.
  const row = db
    .prepare(
      `
    SELECT 1 FROM migration_log
     WHERE state IN ('fs_pending', 'fs_done')
       AND started_at > datetime('now', @ttlCutoff)
       AND (
            @p = old_path
         OR (length(@p) > length(old_path) AND substr(@p, 1, length(old_path) + 1) = old_path || '/')
         OR @p = new_path
         OR (length(@p) > length(new_path) AND substr(@p, 1, length(new_path) + 1) = new_path || '/')
       )
     LIMIT 1
  `,
    )
    .get({
      p: filePath,
      ttlCutoff: `-${PENDING_MIGRATION_TTL_SECONDS} seconds`,
    });
  return row !== undefined;
}

/**
 * Convert migrations stuck in fs_pending/fs_done beyond the stale threshold
 * to state='failed'. Runs at daemon/MCP startup so crashed-process remnants
 * don't accumulate. Returns the number of rows updated.
 */
export function cleanupStaleMigrations(db: BetterSqlite3.Database): number {
  const res = db
    .prepare(
      `
    UPDATE migration_log
       SET state = 'failed',
           error = 'stale_after_crash: non-terminal for over ' || @hours || ' hours',
           finished_at = datetime('now')
     WHERE state IN ('fs_pending', 'fs_done')
       AND started_at <= datetime('now', @cutoff)
  `,
    )
    .run({
      cutoff: `-${STALE_MIGRATION_THRESHOLD_SECONDS} seconds`,
      hours: Math.floor(STALE_MIGRATION_THRESHOLD_SECONDS / 3600),
    });
  return res.changes;
}

function rowToMigration(row: Record<string, unknown>): MigrationLogRow {
  return {
    id: row.id as string,
    oldPath: row.old_path as string,
    newPath: row.new_path as string,
    oldBasename: row.old_basename as string,
    newBasename: row.new_basename as string,
    state: row.state as MigrationState,
    filesPatched: (row.files_patched as number) ?? 0,
    occurrences: (row.occurrences as number) ?? 0,
    sessionsUpdated: (row.sessions_updated as number) ?? 0,
    aliasCreated: Boolean(row.alias_created),
    ccDirRenamed: Boolean(row.cc_dir_renamed),
    startedAt: row.started_at as string,
    finishedAt: (row.finished_at as string | null) ?? null,
    dryRun: Boolean(row.dry_run),
    rolledBackOf: (row.rolled_back_of as string | null) ?? null,
    auditNote: (row.audit_note as string | null) ?? null,
    archived: Boolean(row.archived),
    actor: (row.actor as MigrationActor) ?? 'cli',
    detail: row.detail
      ? (JSON.parse(row.detail as string) as Record<string, unknown>)
      : null,
    error: (row.error as string | null) ?? null,
  };
}
