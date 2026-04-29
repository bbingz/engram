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

import { readdir, stat } from 'node:fs/promises';
import { basename, dirname } from 'node:path';
import type { Database } from '../db.js';

/** Three-state FS presence probe. `unknown` means we got an error other
 *  than ENOENT (typically EACCES / ELOOP / ENOTDIR) — lumping it into
 *  `false` would mislead the user. Codex follow-up minor #6. */
export type PathProbe = 'exists' | 'absent' | 'unknown';

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
    /** Three-state version of the existence probe; kept alongside the
     *  boolean for backward compat. */
    oldPathState: PathProbe;
    newPathState: PathProbe;
    /** Sibling `.engram-move-tmp-*` / `.engram-tmp-*` dirs left behind by
     *  a crashed EXDEV move or killed patch. Empty when the probe dir
     *  couldn't be read (record as unknown via `probeError`). */
    tempArtifacts: string[];
    /** Reason the temp-artifact scan skipped, if any (e.g. parent
     *  directory unreadable). Null on success. */
    probeError: string | null;
  };
  /** Human-readable recommendation, not a prescription. */
  recommendation: string;
}

interface RecoverOptions {
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
    const oldState = await probePath(row.oldPath);
    const newState = await probePath(row.newPath);
    const oldExists = oldState === 'exists';
    const newExists = newState === 'exists';
    const artifacts = await scanTempArtifacts(row.oldPath, row.newPath);

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
        oldPathState: oldState,
        newPathState: newState,
        tempArtifacts: artifacts.paths,
        probeError: artifacts.error,
      },
      recommendation,
    });
  }
  return diagnoses;
}

/** Three-state existence probe — distinguish "confirmed absent" (ENOENT)
 *  from "I have no idea" (EACCES, EIO, ELOOP). */
async function probePath(path: string): Promise<PathProbe> {
  try {
    await stat(path);
    return 'exists';
  } catch (err) {
    const code = (err as { code?: string }).code;
    if (code === 'ENOENT' || code === 'ENOTDIR') return 'absent';
    return 'unknown';
  }
}

/** Scan the parents of oldPath + newPath for `.engram-tmp-*` and
 *  `.engram-move-tmp-*` directories left behind by a crashed move. We
 *  list entries lazily and filter — avoids loading huge dir listings into
 *  the return value. Probing both parents covers EXDEV-style fallbacks
 *  where the temp sits next to the destination. */
async function scanTempArtifacts(
  oldPath: string,
  newPath: string,
): Promise<{ paths: string[]; error: string | null }> {
  const parents = Array.from(
    new Set([dirname(oldPath), dirname(newPath)]),
  ).filter((p) => p && p !== '/' && p !== '.');
  const found: string[] = [];
  const errors: string[] = [];
  for (const parent of parents) {
    try {
      const entries = await readdir(parent);
      for (const name of entries) {
        if (
          name.startsWith('.engram-tmp-') ||
          name.startsWith('.engram-move-tmp-') ||
          // Also the fs-ops sibling temp (safeMoveDir EXDEV path)
          name.startsWith(`${basename(newPath)}.engram-move-tmp-`) ||
          name.startsWith(`${basename(oldPath)}.engram-move-tmp-`)
        ) {
          found.push(`${parent}/${name}`);
        }
      }
    } catch (err) {
      errors.push(`${parent}: ${(err as Error).message}`);
    }
  }
  return {
    paths: found.sort(),
    error: errors.length > 0 ? errors.join('; ') : null,
  };
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
    // Round 4 Codex Minor #9: previously suggested "re-run `engram
    // project move <src> <dst>`" — but since src is gone and dst
    // exists, the orchestrator's preflight would immediately throw
    // ENOENT / DirCollisionError. The actual resolution is either
    // (a) manually finish the DB commit, or (b) mv the dir back and
    // retry. Point the user at the correct path.
    if (!oldExists && newExists)
      return (
        'FS move succeeded; DB commit failed mid-way. ' +
        'To finish: either (a) mv the new path back to the old path and retry `engram project move`, ' +
        "or (b) mark the migration committed directly — connect to ~/.engram/index.sqlite and run `UPDATE migration_log SET state='committed' WHERE id='<this>'`, then run `engram project review <oldPath> <newPath>` to check residual refs. " +
        'Re-running `engram project move <oldPath> <newPath>` as-is WILL NOT work (src gone, dst exists).'
      );
    if (oldExists && newExists)
      return 'Both paths exist — FS work may have been partially undone. Inspect both; prefer manual mv back over retry.';
    return 'Unexpected state. Investigate manually.';
  }
  if (state === 'failed') {
    if (oldExists && !newExists)
      return 'Compensation succeeded — src is back where it started. Safe to ignore and retry later.';
    if (!oldExists && newExists)
      return (
        'FS move completed but DB commit failed and compensation did not reverse the FS. ' +
        "Either (a) manually mv new → old then retry `engram project move`, or (b) mark committed directly: `UPDATE migration_log SET state='committed' WHERE id='<this>'` then `engram project review`."
      );
    if (oldExists && newExists)
      return 'Both paths exist — compensation ran partially. Inspect, then `engram project move` (or manual mv) to reach a consistent state.';
    return 'Neither path exists — likely data loss. Restore from backup.';
  }
  return 'Unknown state';
}
