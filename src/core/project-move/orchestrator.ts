// src/core/project-move/orchestrator.ts — the 7-step project-move pipeline
//
// Wires Phase 1 (DB migration-log + CAS watcher guard) + Phase 2 (FS ops,
// JSONL patch, source scan) into a single transaction-with-compensation.
//
// Pipeline:
//   A. startMigration (state='fs_pending')
//   0. Git dirty check (user-policy decision is in CLI)
//   0.5. acquireLock (prevents concurrent project moves)
//   1. safeMoveDir physical
//   2. Rename per-project dirs for each source that groups by project
//      (Claude Code = encoded cwd, Gemini = basename, iFlow = iflow-encoded)
//   3. Scan all source roots → findReferencingFiles → patchFile (per-file CAS)
//   4. auto_fix_dot_quote on the patched files
//   B. markFsDone (state='fs_done', detail=per-source stats + manifest)
//   C. applyMigrationDb in transaction (state='committed')
//   99. release lock; return PipelineResult
//
// Compensation (Gemini #5): if any FS step throws, reverse the work:
//   - Reverse-patch files using the `manifest` (undo each patchFile)
//   - Rename each source-side dir back (LIFO)
//   - safeMoveDir dst→src back
//   - failMigration(id, error)
//   - release lock

import { randomUUID } from 'node:crypto';
import { unlinkSync } from 'node:fs';
import { rename, stat } from 'node:fs/promises';
import { join } from 'node:path';
import type { Database } from '../db.js';
import { safeMoveDir } from './fs-ops.js';
import {
  applyGeminiProjectsJsonUpdate,
  collectOtherGeminiCwdsSharingBasename,
  planGeminiProjectsJsonUpdate,
  reverseGeminiProjectsJsonUpdate,
} from './gemini-projects-json.js';
import { checkGitDirty, type GitDirtyStatus } from './git-dirty.js';
import { autoFixDotQuote, patchFile } from './jsonl-patch.js';
import { acquireLock, defaultLockPath, releaseLock } from './lock.js';
import { type ReviewResult, reviewScan } from './review.js';
import {
  findReferencingFiles,
  getSourceRoots,
  type SourceId,
  type WalkIssue,
} from './sources.js';

/** Per-source directory rename record. Populated step-by-step; used for
 *  both forward remap (patch hit path → new location) and compensation. */
interface DirRenamePlan {
  sourceId: SourceId;
  oldDir: string;
  newDir: string;
}

/**
 * Pre-flight failure: the target directory for a per-source rename already
 * exists. Thrown BEFORE any physical FS change so the caller can abort
 * without triggering compensation (Codex #2 / Gemini critical #1).
 */
export class DirCollisionError extends Error {
  constructor(
    public sourceId: SourceId,
    public oldDir: string,
    public newDir: string,
  ) {
    super(
      `project-move: ${sourceId} target dir already exists — ${newDir}. ` +
        'Another project is using that path; refusing to overwrite. ' +
        'Move the target aside or merge sessions manually, then retry.',
    );
    this.name = 'DirCollisionError';
  }
}

/**
 * Pre-flight failure: a Gemini (or iFlow) per-project dir is SHARED across
 * multiple projects because the encoding isn't injective. Renaming the
 * dir would silently steal sessions from the other project (Gemini major
 * #3). Refuse to proceed; user must split the dir manually.
 */
export class SharedEncodingCollisionError extends Error {
  constructor(
    public sourceId: SourceId,
    public dir: string,
    public sharingCwds: string[],
  ) {
    super(
      `project-move: ${sourceId} dir ${dir} is shared with other projects ` +
        `[${sharingCwds.join(', ')}]. Renaming would steal their sessions. ` +
        'Manually separate the dirs before retrying.',
    );
    this.name = 'SharedEncodingCollisionError';
  }
}

export interface RunProjectMoveOpts {
  src: string;
  dst: string;
  dryRun?: boolean;
  /** Skip git dirty warning (user already confirmed). */
  force?: boolean;
  /** Archive semantics — informational only; affects migration_log.archived. */
  archived?: boolean;
  /** Where the user intends this as (audit_note). */
  auditNote?: string;
  actor?: 'cli' | 'mcp' | 'swift-ui' | 'batch';
  /** Override home for tests. Passed to getSourceRoots/lock/etc. */
  home?: string;
  /** Override lock path (for tests or alternate engram configs). */
  lockPath?: string;
  /** Set when this move is undoing another migration — writes the link back. */
  rolledBackOf?: string;
}

export interface PerSourceStats {
  id: string;
  root: string;
  filesPatched: number;
  occurrences: number;
  issues: WalkIssue[];
}

export interface PipelineResult {
  migrationId: string;
  state: 'committed' | 'dry-run' | 'failed';
  moveStrategy: 'rename' | 'copy-then-delete' | 'skipped';
  /** True iff the Claude Code encoded-cwd dir was renamed. Kept as a scalar
   *  for backward-compat; `renamedDirs` carries the full list across sources. */
  ccDirRenamed: boolean;
  /** All per-project directories that were renamed during this move. */
  renamedDirs: DirRenamePlan[];
  perSource: PerSourceStats[];
  totalFilesPatched: number;
  totalOccurrences: number;
  sessionsUpdated: number;
  aliasCreated: boolean;
  review: ReviewResult;
  git: GitDirtyStatus;
  /** Error message if state === 'failed'. */
  error?: string;
  /** Files we modified (src + new path) for undo. */
  manifest: Array<{ path: string; occurrences: number }>;
}

/**
 * Main entry point — orchestrates all 7 steps + compensation.
 *
 * Policy gates (CLI is responsible for asking the user):
 *   - Git dirty: if `git.dirty && !opts.force`, throw before any FS change.
 *   - Dry-run: plan + return, no writes.
 */
export async function runProjectMove(
  db: Database,
  opts: RunProjectMoveOpts,
): Promise<PipelineResult> {
  const { src, dst } = opts;
  if (src === dst) {
    throw new Error(`runProjectMove: src === dst (${src})`);
  }
  // Gemini critical #2: reject self-subdirectory moves. fs.cp/rename would
  // blow up mid-way with ERR_FS_CP_DIR_TO_ITS_SUBDIR, but by then the FS
  // mess is already starting. Catch this at step 0 before any side effect.
  if (dst.startsWith(`${src}/`)) {
    throw new Error(
      `runProjectMove: dst (${dst}) is inside src (${src}); cannot move a directory into its own subdirectory`,
    );
  }
  if (src.startsWith(`${dst}/`)) {
    throw new Error(
      `runProjectMove: src (${src}) is inside dst (${dst}); would create a rename loop`,
    );
  }

  // Step 0: git dirty check (mechanism; CLI layer decides policy)
  const git = await checkGitDirty(src);
  if (git.dirty && !opts.force) {
    throw new Error(
      `runProjectMove: ${src} has uncommitted git changes. ` +
        'Commit, stash, or pass force=true to proceed.',
    );
  }

  // Dry-run returns a plan without side effects (other than the git probe)
  if (opts.dryRun) {
    return buildDryRunPlan(opts, git);
  }

  const migrationId = randomUUID();
  const oldBasename = basename(src);
  const newBasename = basename(dst);
  const lockPath = opts.lockPath ?? defaultLockPath(opts.home);

  // Acquire lock BEFORE writing to migration_log. (self-review M1: otherwise
  // a LockBusyError leaves a stale fs_pending row that blocks the watcher
  // for 24h via hasPendingMigrationFor.)
  await acquireLock(migrationId, lockPath);

  // SIGINT handler (Gemini major #5): on Ctrl-C, fail the migration in DB
  // and release the lock BEFORE the process exits so the 24h watcher-blind
  // TTL doesn't kick in. Sync-only calls inside the handler; then exit.
  const sigintHandler = () => {
    try {
      db.failMigration(migrationId, 'interrupted by SIGINT');
    } catch {
      /* best-effort */
    }
    // Sync unlink so release happens before the process dies
    try {
      unlinkSync(lockPath);
    } catch {
      /* best-effort */
    }
    process.exit(130); // conventional for SIGINT
  };
  process.on('SIGINT', sigintHandler);

  // Phase A: persist intent BEFORE touching FS (three-phase log, Phase 1)
  db.startMigration({
    id: migrationId,
    oldPath: src,
    newPath: dst,
    oldBasename,
    newBasename,
    dryRun: false,
    auditNote: opts.auditNote ?? null,
    archived: opts.archived ?? false,
    actor: opts.actor ?? 'cli',
    rolledBackOf: opts.rolledBackOf ?? null,
  });

  const manifest: Array<{ path: string; occurrences: number }> = [];
  const perSource: PerSourceStats[] = [];
  let moveStrategy: PipelineResult['moveStrategy'] = 'skipped';
  const renamedDirs: DirRenamePlan[] = [];
  const skippedDirs: Array<{ sourceId: SourceId; reason: 'noop' | 'missing' }> =
    [];
  // Gemini projects.json plan (if applicable). Built during preflight so
  // compensation can reverse even if apply() throws mid-way.
  let geminiProjectsPlan:
    | import('./gemini-projects-json.js').GeminiProjectsJsonUpdatePlan
    | null = null;
  let geminiProjectsApplied = false;

  try {
    // Step 0.5: compute per-source rename plans BEFORE moving (src exists,
    // dst does not). Each source with a non-null encodeProjectDir contributes
    // one plan; sources with flat layouts (codex/opencode/etc.) are skipped.
    const roots = getSourceRoots(opts.home);
    const dirRenamePlans: DirRenamePlan[] = [];
    for (const root of roots) {
      if (!root.encodeProjectDir) continue;
      const oldName = root.encodeProjectDir(src);
      const newName = root.encodeProjectDir(dst);
      if (oldName === newName) {
        // Lossy encoding may collapse (e.g. iflow `/a/-foo-/p` and
        // `/a/foo/p` both → `-a-foo-p`). Or cross-parent move where
        // basename stayed the same (gemini). Either way, no rename needed.
        skippedDirs.push({ sourceId: root.id, reason: 'noop' });
        continue;
      }
      dirRenamePlans.push({
        sourceId: root.id,
        oldDir: join(root.path, oldName),
        newDir: join(root.path, newName),
      });
    }

    // Step 0.6: pre-flight — catch collisions BEFORE the physical move so
    // we don't have to roll back a potentially multi-GB rename.
    // (Codex MAJOR #2 + Gemini critical #1.)
    for (const plan of dirRenamePlans) {
      try {
        await stat(plan.newDir);
        throw new DirCollisionError(plan.sourceId, plan.oldDir, plan.newDir);
      } catch (err) {
        if (err instanceof DirCollisionError) throw err;
        const e = err as { code?: string };
        if (e.code !== 'ENOENT') throw err;
      }
    }

    // Step 0.7: Gemini-specific probes. Shared-basename hijack + plan the
    // projects.json rewrite. Only runs if gemini-cli is in the plan list.
    const geminiPlan = dirRenamePlans.find((d) => d.sourceId === 'gemini-cli');
    if (geminiPlan) {
      const geminiRoot = roots.find((r) => r.id === 'gemini-cli');
      const projectsFile = geminiRoot
        ? join(geminiRoot.path, '..', 'projects.json')
        : null;
      if (projectsFile) {
        // Gemini major #3: shared-basename hijack. If another cwd maps to
        // the same basename as dst, renaming the dir would steal their
        // sessions.
        const conflicts = await collectOtherGeminiCwdsSharingBasename(
          projectsFile,
          basename(dst),
          src,
        );
        if (conflicts.length > 0) {
          throw new SharedEncodingCollisionError(
            'gemini-cli',
            geminiPlan.oldDir,
            conflicts,
          );
        }
        // Codex MAJOR #1: plan the projects.json rewrite. Snapshot is
        // captured here so compensation can restore even if apply fails.
        geminiProjectsPlan = await planGeminiProjectsJsonUpdate(
          projectsFile,
          src,
          dst,
        );
      }
    }

    // Step 1: physical move
    const moveResult = await safeMoveDir(src, dst);
    moveStrategy = moveResult.strategy;

    // Step 2: rename each source's per-project dir (if present). ENOENT
    // means that source has no record for this project — normal, skip. Any
    // other error bails and triggers compensation. Wrap with sourceId
    // context (self-review + Gemini minor #5) so the user can tell WHICH
    // source failed from the one-line error message.
    for (const plan of dirRenamePlans) {
      try {
        await rename(plan.oldDir, plan.newDir);
        renamedDirs.push(plan);
      } catch (err) {
        const e = err as { code?: string };
        if (e.code === 'ENOENT') {
          skippedDirs.push({ sourceId: plan.sourceId, reason: 'missing' });
          continue;
        }
        throw new Error(
          `project-move: ${plan.sourceId} rename failed (${plan.oldDir} → ${plan.newDir}): ${
            (err as Error).message
          }`,
        );
      }
    }
    const ccDirRenamed = renamedDirs.some((d) => d.sourceId === 'claude-code');

    // Step 2.5: update ~/.gemini/projects.json so the Gemini adapter can
    // reverse-resolve the renamed dir back to the new cwd. (Codex MAJOR #1.)
    if (
      geminiProjectsPlan &&
      renamedDirs.some((d) => d.sourceId === 'gemini-cli')
    ) {
      await applyGeminiProjectsJsonUpdate(geminiProjectsPlan);
      geminiProjectsApplied = true;
    }

    // Step 3: patch JSONL across all sources.
    // Scan at current location (dirs already renamed if applicable) for the
    // OLD path literal. patchFile for each hit runs with bounded parallelism
    // (Gemini major #6) — serial was a perf cliff at 100+ files.
    const PATCH_CONCURRENCY = 50;
    let totalFilesPatched = 0;
    let totalOccurrences = 0;
    for (const root of roots) {
      const issues: WalkIssue[] = [];
      const hits = await findReferencingFiles(root.path, src);
      // Remap hits that live under any renamed dir — defensive: the walker
      // may have cached listings, or returned paths through a stale symlink.
      const remapped = hits.map((file) => {
        for (const d of renamedDirs) {
          if (file.startsWith(`${d.oldDir}/`)) {
            return d.newDir + file.slice(d.oldDir.length);
          }
        }
        return file;
      });
      const perFile = await runWithConcurrency(
        remapped,
        PATCH_CONCURRENCY,
        async (file) => {
          try {
            const count = await patchFile(file, src, dst);
            return { file, count, err: null as Error | null };
          } catch (err) {
            return { file, count: 0, err: err as Error };
          }
        },
      );
      let filesPatched = 0;
      let occurrences = 0;
      for (const r of perFile) {
        if (r.err) {
          issues.push({
            path: r.file,
            reason: 'stat_failed',
            detail: r.err.message,
          });
        } else if (r.count > 0) {
          manifest.push({ path: r.file, occurrences: r.count });
          filesPatched++;
          occurrences += r.count;
        }
      }
      perSource.push({
        id: root.id,
        root: root.path,
        filesPatched,
        occurrences,
        issues,
      });
      totalFilesPatched += filesPatched;
      totalOccurrences += occurrences;
    }

    // Step 4: auto-fix `<old>."` sentence-end pattern (only on files we touched)
    // This is a text-level belt-and-suspenders on top of step 3's regex.
    let dotQuoteExtras = 0;
    for (const entry of [...manifest]) {
      try {
        const { readFile, writeFile } = await import('node:fs/promises');
        const buf = await readFile(entry.path);
        const fixed = autoFixDotQuote(buf, src, dst);
        if (fixed.count > 0) {
          await writeFile(entry.path, fixed.buffer);
          dotQuoteExtras += fixed.count;
          entry.occurrences += fixed.count;
        }
      } catch {
        // skip — main regex already did most of the work
      }
    }
    totalOccurrences += dotQuoteExtras;

    // Phase B: mark FS complete
    db.markMigrationFsDone({
      id: migrationId,
      filesPatched: totalFilesPatched,
      occurrences: totalOccurrences,
      ccDirRenamed,
      detail: {
        move_strategy: moveStrategy,
        per_source: perSource.map((s) => ({
          id: s.id,
          files: s.filesPatched,
          occ: s.occurrences,
          issues: s.issues.length,
        })),
        renamed_dirs: renamedDirs.map((d) => ({
          source: d.sourceId,
          old: d.oldDir,
          new: d.newDir,
        })),
        // Gemini minor #6: record dirs that were *intentionally* skipped
        // (either the encoded name didn't change, or the source had no
        // dir for this project). Auditable without reading the FS.
        skipped_dirs: skippedDirs,
        gemini_projects_json_updated: geminiProjectsApplied,
        manifest_paths: manifest.map((m) => m.path),
      },
    });

    // Phase C: commit DB (sessions + session_local_state + alias + log)
    const dbResult = db.applyMigrationDb({
      migrationId,
      oldPath: src,
      newPath: dst,
      oldBasename,
      newBasename,
    });

    // Step 6: review scan for residual refs (own/other)
    const review = await reviewScan(src, { newPath: dst, home: opts.home });

    process.off('SIGINT', sigintHandler);
    await releaseLock(lockPath);

    return {
      migrationId,
      state: 'committed',
      moveStrategy,
      ccDirRenamed,
      renamedDirs,
      perSource,
      totalFilesPatched,
      totalOccurrences,
      sessionsUpdated: dbResult.sessionsUpdated,
      aliasCreated: dbResult.aliasCreated,
      review,
      git,
      manifest,
    };
  } catch (err) {
    // Compensation: reverse in LIFO order. Collect per-step failures so the
    // migration_log captures the full picture — orchestrator used to swallow
    // these via .catch(()=>{}), leaving the user blind to which files the
    // rollback couldn't restore. (Codex 1a/1b/7 + Gemini 7.)
    //
    // Note: DirCollisionError / SharedEncodingCollisionError are thrown
    // BEFORE any FS side effect (no physical move, no rename). Skip the
    // full compensation in that case — there's nothing to undo, and
    // running it would mis-report "moveRevertError" etc.
    const errorMsg = (err as Error).message || String(err);
    const preflightFailure =
      err instanceof DirCollisionError ||
      err instanceof SharedEncodingCollisionError;
    const report = preflightFailure
      ? {
          patchReverted: 0,
          patchFailed: [] as Array<{ path: string; error: string }>,
          dirsRestored: [] as DirRenamePlan[],
          dirRestoreErrors: [] as Array<{ sourceId: SourceId; error: string }>,
          moveReverted: false,
          moveRevertError: null as string | null,
          geminiProjectsJsonRestored: 'skipped' as const,
        }
      : await compensate(
          manifest,
          src,
          dst,
          renamedDirs,
          geminiProjectsApplied ? geminiProjectsPlan : null,
        );
    const combined = formatFailureWithCompensation(errorMsg, report);
    db.failMigration(migrationId, combined);
    process.off('SIGINT', sigintHandler);
    await releaseLock(lockPath).catch(() => {});
    // Codex Q2 (Phase 4a rev2): preserve the original Error instance so
    // `instanceof LockBusyError` / `ConcurrentModificationError` / etc.
    // continue to work in downstream handlers. We only extend .message
    // with the rollback suffix — the class, name, stack, and any custom
    // fields (like LockBusyError.holder) stay on the original object.
    if (err instanceof Error) {
      err.message = combined;
    }
    throw err;
  }
}

interface CompensationReport {
  patchReverted: number;
  patchFailed: Array<{ path: string; error: string }>;
  dirsRestored: DirRenamePlan[];
  dirRestoreErrors: Array<{ sourceId: SourceId; error: string }>;
  moveReverted: boolean;
  moveRevertError: string | null;
  /** 'skipped' = no projects.json edit was applied; 'restored' = snapshot
   *  rewritten or entry deleted; 'failed' = reverse threw and the file may
   *  be inconsistent (original error included in dirRestoreErrors). */
  geminiProjectsJsonRestored: 'skipped' | 'restored' | 'failed';
}

function formatFailureWithCompensation(
  primary: string,
  report: CompensationReport,
): string {
  const parts: string[] = [primary];
  if (report.patchFailed.length > 0) {
    parts.push(
      `rollback: ${report.patchFailed.length} file(s) could NOT be reverted ` +
        `(e.g. ${report.patchFailed[0].path}: ${report.patchFailed[0].error})`,
    );
  }
  if (report.dirRestoreErrors.length > 0) {
    const first = report.dirRestoreErrors[0];
    parts.push(
      `rollback: ${report.dirRestoreErrors.length} dir rename(s) could NOT be reversed ` +
        `(e.g. ${first.sourceId}: ${first.error})`,
    );
  }
  if (report.geminiProjectsJsonRestored === 'failed') {
    parts.push(
      'rollback: ~/.gemini/projects.json reverse failed — inspect manually',
    );
  }
  if (report.moveRevertError) {
    parts.push(
      `rollback: physical move-back failed — ${report.moveRevertError}`,
    );
  }
  return parts.join(' | ');
}

function basename(p: string): string {
  const parts = p.replace(/\/+$/, '').split('/');
  return parts[parts.length - 1] ?? '';
}

/**
 * Simple bounded-concurrency map. No external dep — we run `limit` workers
 * that pull from an index cursor. Keeps input order in the output array.
 */
async function runWithConcurrency<T, R>(
  items: T[],
  limit: number,
  fn: (item: T, index: number) => Promise<R>,
): Promise<R[]> {
  if (items.length === 0) return [];
  const out = new Array<R>(items.length);
  let cursor = 0;
  const worker = async () => {
    while (true) {
      const i = cursor++;
      if (i >= items.length) break;
      out[i] = await fn(items[i], i);
    }
  };
  const n = Math.min(limit, items.length);
  await Promise.all(Array.from({ length: n }, () => worker()));
  return out;
}

async function compensate(
  manifest: Array<{ path: string; occurrences: number }>,
  originalSrc: string,
  attemptedDst: string,
  renamedDirs: DirRenamePlan[],
  geminiProjectsPlan:
    | import('./gemini-projects-json.js').GeminiProjectsJsonUpdatePlan
    | null,
): Promise<CompensationReport> {
  const report: CompensationReport = {
    patchReverted: 0,
    patchFailed: [],
    dirsRestored: [],
    dirRestoreErrors: [],
    moveReverted: false,
    moveRevertError: null,
    geminiProjectsJsonRestored: 'skipped',
  };
  // Reverse file patches in LIFO order — last patched first
  for (const entry of [...manifest].reverse()) {
    try {
      await patchFile(entry.path, attemptedDst, originalSrc);
      report.patchReverted++;
    } catch (err) {
      report.patchFailed.push({
        path: entry.path,
        error: (err as Error).message,
      });
    }
  }
  // Reverse the projects.json rewrite FIRST — it was applied after dir
  // renames, so LIFO means it comes back to the original state before we
  // move the dir back (otherwise the adapter would briefly see newCwd →
  // newName pointing at an oldDir-named tmp dir).
  if (geminiProjectsPlan) {
    try {
      await reverseGeminiProjectsJsonUpdate(geminiProjectsPlan);
      report.geminiProjectsJsonRestored = 'restored';
    } catch (err) {
      report.geminiProjectsJsonRestored = 'failed';
      report.dirRestoreErrors.push({
        sourceId: 'gemini-cli',
        error: `projects.json reverse: ${(err as Error).message}`,
      });
    }
  }
  // Reverse each per-source dir rename (LIFO — last renamed first)
  for (const d of [...renamedDirs].reverse()) {
    try {
      await rename(d.newDir, d.oldDir);
      report.dirsRestored.push(d);
    } catch (err) {
      report.dirRestoreErrors.push({
        sourceId: d.sourceId,
        error: (err as Error).message,
      });
    }
  }
  // Reverse the physical move (only if dst exists and src doesn't)
  try {
    await safeMoveDir(attemptedDst, originalSrc);
    report.moveReverted = true;
  } catch (err) {
    report.moveReverted = false;
    report.moveRevertError = (err as Error).message;
  }
  return report;
}

/** Exported so archive / batch can reuse the same dry-run shape without
 *  duplicating the field list (Codex Q4). */
export function buildDryRunPlan(
  _opts: RunProjectMoveOpts,
  git: GitDirtyStatus,
): PipelineResult {
  return {
    migrationId: 'dry-run',
    state: 'dry-run',
    moveStrategy: 'skipped',
    ccDirRenamed: false,
    renamedDirs: [],
    perSource: [],
    totalFilesPatched: 0,
    totalOccurrences: 0,
    sessionsUpdated: 0,
    aliasCreated: false,
    review: { own: [], other: [] },
    git,
    manifest: [],
  };
}
