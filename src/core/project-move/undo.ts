// src/core/project-move/undo.ts — reverse a committed project-move migration.
//
// Strategy: look up the migration_log row; if state='committed', run the
// orchestrator again with swapped src/dst and rolledBackOf set. That
// records a new migration_log row pointing back at the original, so the
// audit trail shows both directions.
//
// For non-committed states (fs_pending / fs_done / failed), refuse — use
// `recover` instead. Undoing a failed migration risks inverting partial
// work; recover() is the safer tool.

import { stat } from 'node:fs/promises';
import type { Database } from '../db.js';
import { type PipelineResult, runProjectMove } from './orchestrator.js';

export class UndoNotAllowedError extends Error {
  constructor(
    public migrationId: string,
    public state: string,
  ) {
    super(
      `undoMigration: cannot undo migration ${migrationId} in state '${state}'. ` +
        "Only 'committed' migrations can be undone. Run `engram project recover` " +
        'for non-terminal or failed migrations.',
    );
    this.name = 'UndoNotAllowedError';
  }
}

export class UndoStaleError extends Error {
  constructor(migrationId: string, reason: string) {
    super(
      `undoMigration: refusing to undo ${migrationId} — ${reason}. ` +
        'The migration is no longer the last one touching these paths. ' +
        'Undo the later migrations first, or manually restore from backup.',
    );
    this.name = 'UndoStaleError';
  }
}

interface UndoOptions {
  /** Override home for tests. */
  home?: string;
  /** Override lock path for tests. */
  lockPath?: string;
  /** Skip git dirty check on the destination (since we're reversing). */
  force?: boolean;
  /** Caller label recorded in migration_log.actor. Defaults to 'cli'. */
  actor?: 'cli' | 'mcp' | 'swift-ui' | 'batch';
}

/**
 * Undo a committed migration by running the orchestrator in reverse.
 * Writes a NEW migration_log row (state='committed') with
 * `rolledBackOf` = the original id.
 */
export async function undoMigration(
  db: Database,
  migrationId: string,
  opts: UndoOptions = {},
): Promise<PipelineResult> {
  const original = db.findMigration(migrationId);
  if (!original) {
    throw new Error(`undoMigration: migration ${migrationId} not found`);
  }
  if (original.state !== 'committed') {
    throw new UndoNotAllowedError(migrationId, original.state);
  }

  // Validate newPath still exists on disk and the affected sessions still
  // point at it. Codex 3a/3b + self M3: if another migration has already
  // moved newPath somewhere else, undoing this one would drag the WRONG
  // directory back to oldPath.
  try {
    await stat(original.newPath);
  } catch {
    throw new UndoStaleError(
      migrationId,
      `newPath (${original.newPath}) no longer exists — it was likely moved by a later migration`,
    );
  }
  const affectedIds = Array.isArray(original.detail?.affectedSessionIds)
    ? (original.detail.affectedSessionIds as string[])
    : [];
  if (affectedIds.length > 0) {
    const sample = db.getSession(affectedIds[0]);
    if (sample && sample.cwd !== original.newPath) {
      // One of the affected sessions now points elsewhere — a later migration
      // or manual edit has overlaid this one.
      throw new UndoStaleError(
        migrationId,
        `session ${affectedIds[0].slice(0, 8)} cwd is now ${sample.cwd}, not ${original.newPath}`,
      );
    }
  }

  // Reverse move: new src = original dst, new dst = original src
  return runProjectMove(db, {
    src: original.newPath,
    dst: original.oldPath,
    auditNote: `Undo of migration ${migrationId}`,
    actor: opts.actor ?? 'cli',
    force: opts.force,
    home: opts.home,
    lockPath: opts.lockPath,
    rolledBackOf: migrationId,
  });
}
