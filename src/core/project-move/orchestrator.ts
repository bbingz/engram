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
import { join, resolve as pathResolve } from 'node:path';
import type { Database } from '../db.js';
import { safeMoveDir } from './fs-ops.js';
import {
  applyGeminiProjectsJsonUpdate,
  collectOtherGeminiCwdsSharingBasename,
  type GeminiProjectsJsonUpdatePlan,
  planGeminiProjectsJsonUpdate,
  reverseGeminiProjectsJsonUpdate,
} from './gemini-projects-json.js';
import { checkGitDirty, type GitDirtyStatus } from './git-dirty.js';
import { patchFile } from './jsonl-patch.js';
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
  /** Per-project directories intentionally NOT renamed. `noop` = encoded
   *  dir name is the same before/after (e.g. content-only source, or
   *  iFlow lossy encoding collapse). `missing` = no dir exists for this
   *  project at this source. Round 4 Critical: previously lived only in
   *  migration_log.detail so CLI/Swift couldn't show the user which
   *  sources skipped the rename. */
  skippedDirs: Array<{ sourceId: SourceId; reason: 'noop' | 'missing' }>;
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
  const rawSrc = opts.src;
  const rawDst = opts.dst;
  if (!rawSrc || !rawDst) {
    // Empty paths are a caller bug; catch before downstream code (the
    // dry-run scanner would infinite-loop on an empty needle).
    throw new Error(
      `runProjectMove: src and dst must be non-empty absolute paths (got src="${rawSrc}", dst="${rawDst}")`,
    );
  }
  // Canonicalize BEFORE the string-level guards so `/x/a/../proj` vs
  // `/x/proj` and trailing-slash variants don't slip past (Codex follow-up
  // critical #1 — only the HTTP layer normalized previously; MCP / CLI /
  // batch callers could feed unresolved paths straight through).
  const src = pathResolve(rawSrc);
  const dst = pathResolve(rawDst);
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

  // Dry-run returns a plan without side effects (other than the git probe +
  // a read-only scan for impact preview). Previously a stub with 0/0 counts,
  // surfaced by the Swift UI "Dry-run impact" always reading 0 regardless
  // of reality — fixed by actually scanning the sources without patching.
  // Pass the resolved src/dst so the scanner sees the canonical paths.
  if (opts.dryRun) {
    return await buildDryRunPlan({ ...opts, src, dst }, git);
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
  let geminiProjectsPlan: GeminiProjectsJsonUpdatePlan | null = null;
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
    //
    // Round 4 Critical (Codex #3 / reviewer C4): on macOS APFS (case
    // insensitive by default), `stat(plan.newDir)` succeeds for a
    // case-only rename (Foo → foo) because the OS resolves to the same
    // inode. Previously that falsely triggered DirCollisionError. Use
    // realpath to distinguish "dst points to the same dir as src"
    // (legitimate case rename — allow) from "dst is a different dir
    // that happens to exist" (real collision — refuse).
    const { realpath } = await import('node:fs/promises');
    for (const plan of dirRenamePlans) {
      try {
        await stat(plan.newDir);
      } catch (err) {
        const e = err as { code?: string };
        if (e.code === 'ENOENT') continue; // clean path
        throw err;
      }
      // newDir exists — check if it's actually the same inode as oldDir
      // (case-only rename on case-insensitive FS).
      try {
        const oldReal = await realpath(plan.oldDir);
        const newReal = await realpath(plan.newDir);
        if (oldReal === newReal) continue; // same dir, legitimate rename
      } catch {
        // realpath failed → treat as a collision to be safe.
      }
      throw new DirCollisionError(plan.sourceId, plan.oldDir, plan.newDir);
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
          // Round 4 Critical (reviewer C2): patchFile used to silently
          // downgrade every error to a WalkIssue — so InvalidUtf8Error
          // and ConcurrentModificationError on files we knew were
          // referencing `src` left a half-patched project shipped as
          // state='committed'. Now we classify: errors that mean "we
          // can't guarantee this file was patched correctly" propagate
          // and trigger full compensation; transient per-file EACCES
          // (file went away under us, or permission flip mid-scan)
          // becomes a WalkIssue the UI can surface.
          const name = r.err.name;
          const isHard =
            name === 'InvalidUtf8Error' ||
            name === 'ConcurrentModificationError';
          if (isHard) {
            throw r.err;
          }
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

    // Step 4 (removed Round 4): the dot-quote fallback sweep used to live
    // here as a separate readFile/writeFile pass, bypassing patchFile's
    // CAS — under concurrent writes this could silently overwrite another
    // process's append. Now folded into patchFile via
    // patchBufferWithDotQuote, so every rewrite is atomic AND compensation
    // (which replays patchFile in reverse) automatically covers it.

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
      skippedDirs,
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
  geminiProjectsPlan: GeminiProjectsJsonUpdatePlan | null,
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

/**
 * Build the dry-run plan — shape matches a committed PipelineResult but
 * state='dry-run' and no FS side effects. Performs a read-only scan so the
 * UI "Dry-run impact" box reports the actual file / occurrence count the
 * user would see if they ran the move. Exported so archive / batch can
 * reuse the same shape (Codex Q4).
 *
 * Large-file safety: occurrence counting reads each matched file into
 * memory; files above DRY_RUN_READ_CAP are counted as 1 occurrence without
 * reading to avoid OOM on pathological session stores.
 */
const DRY_RUN_READ_CAP = 50 * 1024 * 1024; // 50 MiB

export async function buildDryRunPlan(
  opts: RunProjectMoveOpts,
  git: GitDirtyStatus,
): Promise<PipelineResult> {
  const { src, dst } = opts;
  const roots = getSourceRoots(opts.home);

  // Same dir-rename plan shape as the main pipeline — lets the UI show which
  // per-project dirs would be renamed even though we don't touch them here.
  // Round 4: also populate `skippedDirs` so the UI can surface which
  // sources will NOT be renamed (iFlow lossy collapse, no-op encoding,
  // or project absent on disk) — previously these were silent.
  const renamedDirs: DirRenamePlan[] = [];
  const skippedDirs: Array<{
    sourceId: SourceId;
    reason: 'noop' | 'missing';
  }> = [];
  for (const root of roots) {
    if (!root.encodeProjectDir) continue;
    const oldName = root.encodeProjectDir(src);
    const newName = root.encodeProjectDir(dst);
    if (oldName === newName) {
      // encodeProjectDir produced the same name — lossy encoding (iFlow)
      // or semantically equivalent rename. Content still gets patched.
      skippedDirs.push({ sourceId: root.id, reason: 'noop' });
      continue;
    }
    const plan: DirRenamePlan = {
      sourceId: root.id,
      oldDir: join(root.path, oldName),
      newDir: join(root.path, newName),
    };
    try {
      await stat(plan.oldDir);
      renamedDirs.push(plan);
    } catch {
      // oldDir absent on this source — project never had history here.
      skippedDirs.push({ sourceId: root.id, reason: 'missing' });
    }
  }

  // Scan every source root for files referencing `src`. Count via byte-level
  // split on the needle so the reported "occurrences" matches what the real
  // patcher would rewrite. Populate `manifest` with the per-file breakdown
  // so the UI can show *which* files will be patched (Round 4 feedback:
  // users won't trust a bare "N files" count without being able to inspect).
  const { readFile } = await import('node:fs/promises');
  const perSource: PerSourceStats[] = [];
  const manifest: Array<{ path: string; occurrences: number }> = [];
  let totalFilesPatched = 0;
  let totalOccurrences = 0;
  const srcBuf = Buffer.from(src, 'utf8');

  for (const root of roots) {
    const hits = await findReferencingFiles(root.path, src);
    let filesPatched = 0;
    let occurrences = 0;
    const issues: WalkIssue[] = [];
    for (const file of hits) {
      // Round 4 (Codex #6 / reviewer M3): filesPatched used to increment
      // up front — so oversized/unreadable files still contributed to the
      // "N files will be patched" banner even though they'd actually be
      // skipped. Now we only count a file after it passes the size + read
      // gates; skipped files show up in `issues` instead.
      try {
        const st = await stat(file);
        if (st.size > DRY_RUN_READ_CAP) {
          issues.push({
            path: file,
            reason: 'too_large',
            detail: `${st.size} bytes > cap ${DRY_RUN_READ_CAP}`,
          });
          continue;
        }
        const buf = await readFile(file);
        let fileOccurrences = 0;
        let idx = buf.indexOf(srcBuf);
        while (idx !== -1) {
          fileOccurrences++;
          idx = buf.indexOf(srcBuf, idx + srcBuf.length);
        }
        if (fileOccurrences > 0) {
          filesPatched++;
          occurrences += fileOccurrences;
          manifest.push({ path: file, occurrences: fileOccurrences });
        }
      } catch (err) {
        // Codex follow-up important #3: don't swallow the error. The file
        // was found by grep, so it exists — if we can't stat/read, that's
        // a permissions issue the user should know about.
        issues.push({
          path: file,
          reason: 'stat_failed',
          detail: (err as Error).message,
        });
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

  const ccDirRenamed = renamedDirs.some((d) => d.sourceId === 'claude-code');

  return {
    migrationId: 'dry-run',
    state: 'dry-run',
    moveStrategy: 'skipped',
    ccDirRenamed,
    renamedDirs,
    skippedDirs,
    perSource,
    totalFilesPatched,
    totalOccurrences,
    sessionsUpdated: 0,
    aliasCreated: false,
    review: { own: [], other: [] },
    git,
    manifest,
  };
}
