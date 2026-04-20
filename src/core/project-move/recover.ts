// src/core/project-move/recover.ts — surface stuck migrations for manual review
//
// The orchestrator is transactional for the happy path. But kill -9, OS
// crash, or truly catastrophic FS failure can leave a migration_log row in
// state='fs_pending' or 'fs_done' with the filesystem in some intermediate
// state. cleanupStaleMigrations (Phase 1) flips them to state='failed'
// after 24h so the watcher guard stops blocking, but the on-disk artifacts
// (half-moved dir, leftover .engram-tmp, orphaned CC dir) remain.
//
// `engram project recover` (CLI) reads the log + probes the FS to produce
// a diagnostic report. It deliberately does NOT auto-fix anything; the user
// decides based on the report whether to:
//   1. manually restore src from backup
//   2. run `engram project move <partial-dst> <src>` to reverse
//   3. accept the partial state and `engram project log-delete <id>`

import { stat } from 'node:fs/promises';
import type { Database } from '../db.js';

export interface RecoverDiagnosis {
  migrationId: string;
  state: string;
  oldPath: string;
  newPath: string;
  startedAt: string;
  finishedAt: string | null;
  error: string | null;
  /** Filesystem observations — help the user decide what to do. */
  fs: {
    oldPathExists: boolean;
    newPathExists: boolean;
    tempArtifacts: string[]; // .engram-tmp-*, .engram-move-tmp-* residue
  };
  /** Human-readable recommendation, not a prescription. */
  recommendation: string;
}

export interface RecoverOptions {
  /** Only report migrations since this ISO timestamp. */
  since?: string;
  /** Include committed migrations too (default: only non-terminal + failed). */
  includeCommitted?: boolean;
}

/**
 * Inspect migration_log for non-terminal / failed rows and report the FS
 * state at each. Returns a list of diagnoses for the caller (CLI or MCP)
 * to present. Does not modify anything.
 */
export async function diagnoseStuckMigrations(
  db: Database,
  opts: RecoverOptions = {},
): Promise<RecoverDiagnosis[]> {
  const states: Array<'fs_pending' | 'fs_done' | 'failed' | 'committed'> =
    opts.includeCommitted
      ? ['fs_pending', 'fs_done', 'failed', 'committed']
      : ['fs_pending', 'fs_done', 'failed'];
  const rows = db.listMigrations({ state: states, since: opts.since });

  const diagnoses: RecoverDiagnosis[] = [];
  for (const row of rows) {
    const oldExists = await exists(row.oldPath);
    const newExists = await exists(row.newPath);

    const recommendation = buildRecommendation(row.state, oldExists, newExists);

    diagnoses.push({
      migrationId: row.id,
      state: row.state,
      oldPath: row.oldPath,
      newPath: row.newPath,
      startedAt: row.startedAt,
      finishedAt: row.finishedAt,
      error: row.error,
      fs: {
        oldPathExists: oldExists,
        newPathExists: newExists,
        tempArtifacts: [], // TODO Phase 3.1: scan for .engram-move-tmp-* siblings
      },
      recommendation,
    });
  }
  return diagnoses;
}

async function exists(path: string): Promise<boolean> {
  try {
    await stat(path);
    return true;
  } catch {
    return false;
  }
}

function buildRecommendation(
  state: string,
  oldExists: boolean,
  newExists: boolean,
): string {
  // Codex major #10: previous text referenced commands (log-delete,
  // commit-migration, log-fix) that don't exist in the CLI. Rewritten to
  // point only at real affordances: `engram project undo`, manual mv,
  // restore-from-backup.
  if (state === 'committed') {
    if (newExists && !oldExists) return 'OK — move completed as logged.';
    if (oldExists && !newExists)
      return 'Anomaly — log says committed but src still exists. Investigate manually; consider `engram project undo <id>`.';
    return 'Anomaly — both or neither paths present. Investigate.';
  }
  if (state === 'fs_pending') {
    if (oldExists && !newExists)
      return 'FS untouched. Safe to ignore; retry the move when ready. The stale log row auto-fails after 24h.';
    if (oldExists && newExists)
      return 'Both paths exist — partial fs.cp may have occurred. Inspect new path; remove it manually if bogus.';
    if (!oldExists && newExists)
      return "Move seems to have actually succeeded; DB log did not catch up. Manual fix: UPDATE migration_log SET state='committed' WHERE id=<this>. Then re-run `engram project move` to sync DB cwd/source_locator.";
    return 'Neither path exists — something catastrophic happened. Restore from backup.';
  }
  if (state === 'fs_done') {
    if (!oldExists && newExists)
      return 'FS move succeeded; DB commit failed. Re-run `engram project move <src> <dst>` with the same args — it will re-apply step 5 idempotently.';
    if (oldExists && newExists)
      return 'Both paths exist — FS work may have been partially undone. Inspect both; prefer manual mv back over retry.';
    return 'Unexpected state. Investigate manually.';
  }
  if (state === 'failed') {
    if (oldExists && !newExists)
      return 'Compensation succeeded — src is back where it started. Safe to ignore and retry later.';
    if (!oldExists && newExists)
      return 'FS move completed but DB commit failed. Re-run `engram project move` with same args to finish the DB side.';
    if (oldExists && newExists)
      return 'Both paths exist — compensation ran partially. Inspect, then `engram project move` (or manual mv) to reach a consistent state.';
    return 'Neither path exists — likely data loss. Restore from backup.';
  }
  return 'Unknown state';
}
