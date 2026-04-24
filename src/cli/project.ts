// src/cli/project.ts — CLI for `engram project {move,review,audit,archive,undo,list,recover,move-batch,orphan-scan}`.
//
// Minimal arg parsing — no yargs; the subcommands are simple.

import { mkdir } from 'node:fs/promises';
import { homedir } from 'node:os';
import { dirname, resolve } from 'node:path';
import { Database } from '../core/db.js';
import { expandHome } from '../core/project-move/paths.js';

/** CLI equivalent of resolving a user-provided path: expand `~`, then
 *  path.resolve (handles relative paths against cwd). */
function normalizePath(p: string): string {
  return resolve(expandHome(p));
}

import {
  type ArchiveCategory,
  suggestArchiveTarget,
} from '../core/project-move/archive.js';
import { loadBatchFile, runBatch } from '../core/project-move/batch.js';
import { runProjectMove } from '../core/project-move/orchestrator.js';
import { diagnoseStuckMigrations } from '../core/project-move/recover.js';
import { reviewScan } from '../core/project-move/review.js';
import { undoMigration } from '../core/project-move/undo.js';

const DB_PATH = resolve(homedir(), '.engram', 'index.sqlite');

const COLOR = {
  red: '\x1b[31m',
  green: '\x1b[32m',
  yellow: '\x1b[33m',
  dim: '\x1b[2m',
  reset: '\x1b[0m',
};

function log(...args: unknown[]): void {
  console.log(...args);
}

function die(msg: string, code = 1): never {
  console.error(`${COLOR.red}✗${COLOR.reset} ${msg}`);
  process.exit(code);
}

interface ParsedFlags {
  positional: string[];
  yes: boolean;
  force: boolean;
  dryRun: boolean;
  archive: boolean;
  archiveTo?: ArchiveCategory;
  note?: string;
  format: 'text' | 'json' | 'md';
  includeCommitted: boolean;
  since?: string;
}

function parseFlags(args: string[]): ParsedFlags {
  const out: ParsedFlags = {
    positional: [],
    yes: false,
    force: false,
    dryRun: false,
    archive: false,
    format: 'text',
    includeCommitted: false,
  };
  for (let i = 0; i < args.length; i++) {
    const a = args[i];
    if (a === '-y' || a === '--yes') out.yes = true;
    else if (a === '-n' || a === '--dry-run') out.dryRun = true;
    else if (a === '--force') out.force = true;
    else if (a === '--archive') out.archive = true;
    else if (a === '--to') out.archiveTo = args[++i] as ArchiveCategory;
    else if (a === '--note') out.note = args[++i];
    else if (a === '--format') out.format = args[++i] as ParsedFlags['format'];
    else if (a === '--include-committed') out.includeCommitted = true;
    else if (a === '--since') out.since = args[++i];
    else if (a.startsWith('-')) die(`unknown flag: ${a}`);
    else out.positional.push(a);
  }
  return out;
}

async function cmdMove(args: string[]): Promise<void> {
  const flags = parseFlags(args);
  if (flags.positional.length !== 2) {
    die(
      'usage: engram project move <src> <dst> [-y] [-n] [--force] [--note "..."]',
    );
  }
  const [src, dst] = flags.positional.map(normalizePath);
  const db = new Database(DB_PATH);
  try {
    // Dry-run first to show plan + git state, then prompt, then real move.
    // (We accept the 2x git stat cost; self-review m3 — it's cheap and
    // keeps the interactive flow simple. Alt: skip dry-run when --yes.)
    if (!flags.yes && !flags.dryRun) {
      const plan = await runProjectMove(db, { src, dst, dryRun: true });
      log(`${COLOR.dim}--- plan ---${COLOR.reset}`);
      log(`[1] mv  ${src} → ${dst}`);
      log(
        `[2] patch ${plan.totalFilesPatched} file(s) across ${plan.perSource.filter((p) => p.filesPatched > 0).length} source(s) · ${plan.totalOccurrences} occurrence(s)`,
      );
      // Round 4 Gemini Important: show per-source breakdown so users can
      // see which sources participate (dir rename + content patch) vs
      // content-only vs skipped.
      for (const p of plan.perSource) {
        if (p.filesPatched === 0) continue;
        const willRename = plan.renamedDirs.some((d) => d.sourceId === p.id);
        const role = willRename ? 'rename+patch' : 'content patch';
        log(
          `    ${COLOR.dim}- ${p.id}: ${role}, ${p.filesPatched} file(s) · ${p.occurrences} occurrence(s)${COLOR.reset}`,
        );
      }
      // Round 4 Critical: skippedDirs were silent — surface so users
      // know which sources will NOT be renamed (iFlow lossy collapse,
      // no project dir, etc.) instead of assuming all 7 participated.
      if (plan.skippedDirs.length > 0) {
        log(`${COLOR.dim}--- skipped (no dir rename) ---${COLOR.reset}`);
        for (const s of plan.skippedDirs) {
          const reasonLabel =
            s.reason === 'noop'
              ? 'encoded name unchanged (content-only)'
              : 'no dir on disk for this project';
          log(`    ${COLOR.dim}- ${s.sourceId}: ${reasonLabel}${COLOR.reset}`);
        }
      }
      // Dry-run issues (too_large / stat_failed) — hidden failures the
      // user should see BEFORE committing.
      const allIssues = plan.perSource.flatMap((p) => p.issues);
      if (allIssues.length > 0) {
        log(
          `${COLOR.yellow}!${COLOR.reset} ${allIssues.length} file(s) could not be scanned:`,
        );
        for (const i of allIssues.slice(0, 5)) {
          log(`    ${COLOR.dim}[${i.reason}] ${i.path}${COLOR.reset}`);
        }
        if (allIssues.length > 5) {
          log(
            `    ${COLOR.dim}... and ${allIssues.length - 5} more${COLOR.reset}`,
          );
        }
      }
      if (plan.git.dirty) {
        log(
          `${COLOR.yellow}!${COLOR.reset} git: ${src} has uncommitted changes (${plan.git.untrackedOnly ? 'untracked only' : 'tracked changes'})`,
        );
      }
      const ans = await prompt('\nProceed? [y/N] ');
      if (ans.trim().toLowerCase() !== 'y') {
        log('aborted');
        return;
      }
    }

    const result = await runProjectMove(db, {
      src,
      dst,
      force: flags.force,
      dryRun: flags.dryRun,
      auditNote: flags.note,
      actor: 'cli',
    });

    if (result.state === 'dry-run') {
      log(`${COLOR.dim}(dry-run) no changes made${COLOR.reset}`);
      return;
    }
    log(
      `${COLOR.green}✓${COLOR.reset} moved via ${result.moveStrategy}; ` +
        `CC dir renamed=${result.ccDirRenamed}; ` +
        `patched ${result.totalFilesPatched} file(s) with ${result.totalOccurrences} replacement(s); ` +
        `sessions_updated=${result.sessionsUpdated}; alias_created=${result.aliasCreated}`,
    );
    if (result.skippedDirs.length > 0) {
      const lossy = result.skippedDirs.filter((s) => s.reason === 'noop');
      if (lossy.length > 0) {
        log(
          `${COLOR.yellow}!${COLOR.reset} ${lossy.length} source(s) had encoded name unchanged (content-only patch): ${lossy.map((s) => s.sourceId).join(', ')}`,
        );
      }
    }
    if (result.review.own.length > 0) {
      log(
        `${COLOR.yellow}!${COLOR.reset} ${result.review.own.length} own-scope residual ref(s) — manual review suggested:`,
      );
      for (const p of result.review.own.slice(0, 5))
        log(`    ${COLOR.dim}${p}${COLOR.reset}`);
    }
    if (result.review.other.length > 0) {
      log(
        `${COLOR.dim}  (${result.review.other.length} historical mention(s) in unrelated conversations — left as record)${COLOR.reset}`,
      );
    }
    log(`${COLOR.dim}migration id: ${result.migrationId}${COLOR.reset}`);
  } finally {
    db.close();
  }
}

async function cmdReview(args: string[]): Promise<void> {
  const flags = parseFlags(args);
  if (flags.positional.length !== 2) {
    die(
      'usage: engram project review <old-path> <new-path> [--format text|md]',
    );
  }
  const [oldPath, newPath] = flags.positional.map(normalizePath);
  const r = await reviewScan(oldPath, { newPath });

  if (flags.format === 'md') {
    const name = newPath.split('/').pop() ?? newPath;
    log(`| ${name} | ${r.own.length} | ${r.other.length} | - |`);
    return;
  }
  log(`${COLOR.dim}--- review: ${oldPath} → ${newPath} ---${COLOR.reset}`);
  if (r.own.length > 0) {
    log(
      `${COLOR.yellow}!${COLOR.reset} ${r.own.length} file(s) in project scope still reference old path:`,
    );
    for (const p of r.own.slice(0, 8))
      log(`    ${COLOR.dim}${p}${COLOR.reset}`);
    if (r.own.length > 8)
      log(`    ${COLOR.dim}... (${r.own.length - 8} more)${COLOR.reset}`);
  } else {
    log(`${COLOR.green}✓${COLOR.reset} 0 stale refs in project scope`);
  }
  if (r.other.length > 0) {
    log(
      `${COLOR.dim}  (${r.other.length} mention(s) in unrelated conversations — left as historical record)${COLOR.reset}`,
    );
  }
}

async function cmdArchive(args: string[]): Promise<void> {
  const flags = parseFlags(args);
  if (flags.positional.length !== 1) {
    die(
      'usage: engram project archive <src> [--to 历史脚本|空项目|归档完成] [-y]',
    );
  }
  const src = normalizePath(flags.positional[0]);
  const db = new Database(DB_PATH);
  try {
    // Pass --to through as forceCategory so ambiguous projects (rule 4) don't
    // crash when the user already said which bucket (B2 fix).
    const suggestion = await suggestArchiveTarget(src, {
      forceCategory: flags.archiveTo,
    });
    const dst = suggestion.dst;
    log(`${COLOR.dim}suggested:${COLOR.reset} ${dst}`);
    log(`${COLOR.dim}reason:${COLOR.reset} ${suggestion.reason}`);
    if (flags.dryRun) {
      log(`${COLOR.dim}(dry-run) no changes made${COLOR.reset}`);
      return;
    }
    if (!flags.yes) {
      const ans = await prompt('\nProceed? [y/N] ');
      if (ans.trim().toLowerCase() !== 'y') {
        log('aborted');
        return;
      }
    }
    // Ensure _archive/<category>/ exists before the rename hop
    await mkdir(dirname(dst), { recursive: true });
    const result = await runProjectMove(db, {
      src,
      dst,
      archived: true,
      actor: 'cli',
      auditNote: flags.note ?? `archive: ${suggestion.reason}`,
      force: flags.force,
    });
    log(
      `${COLOR.green}✓${COLOR.reset} archived; migration id: ${result.migrationId}`,
    );
  } finally {
    db.close();
  }
}

async function cmdUndo(args: string[]): Promise<void> {
  const flags = parseFlags(args);
  if (flags.positional.length !== 1) {
    die('usage: engram project undo <migration-id>');
  }
  const db = new Database(DB_PATH);
  try {
    const result = await undoMigration(db, flags.positional[0], {
      force: flags.force,
    });
    log(
      `${COLOR.green}✓${COLOR.reset} undone; new migration id: ${result.migrationId}`,
    );
  } finally {
    db.close();
  }
}

async function cmdList(args: string[]): Promise<void> {
  const flags = parseFlags(args);
  const db = new Database(DB_PATH);
  try {
    const rows = db.listMigrations({ limit: 20, since: flags.since });
    if (rows.length === 0) {
      log(`${COLOR.dim}(no migrations recorded)${COLOR.reset}`);
      return;
    }
    for (const r of rows) {
      const marker =
        r.state === 'committed'
          ? `${COLOR.green}✓`
          : r.state === 'failed'
            ? `${COLOR.red}✗`
            : `${COLOR.yellow}…`;
      log(
        `${marker}${COLOR.reset} ${r.id.slice(0, 8)}  ${r.state.padEnd(11)}  ${r.oldBasename} → ${r.newBasename}  ${COLOR.dim}${r.startedAt}${COLOR.reset}`,
      );
    }
  } finally {
    db.close();
  }
}

async function cmdRecover(args: string[]): Promise<void> {
  const flags = parseFlags(args);
  const db = new Database(DB_PATH);
  try {
    const diag = await diagnoseStuckMigrations(db, {
      since: flags.since,
      includeCommitted: flags.includeCommitted,
    });
    if (diag.length === 0) {
      log(`${COLOR.green}✓${COLOR.reset} no stuck migrations`);
      return;
    }
    for (const d of diag) {
      log(`\n${COLOR.yellow}⚠${COLOR.reset} ${d.migrationId}  [${d.state}]`);
      log(`    old: ${d.oldPath}  (exists=${d.fs.oldPathExists})`);
      log(`    new: ${d.newPath}  (exists=${d.fs.newPathExists})`);
      if (d.error) log(`    ${COLOR.dim}error: ${d.error}${COLOR.reset}`);
      log(`    → ${d.recommendation}`);
    }
  } finally {
    db.close();
  }
}

async function cmdBatch(args: string[]): Promise<void> {
  const flags = parseFlags(args);
  if (flags.positional.length !== 1) {
    die('usage: engram project move-batch <yaml-file>');
  }
  const yamlPath = resolve(flags.positional[0]);
  const db = new Database(DB_PATH);
  try {
    const doc = await loadBatchFile(yamlPath);
    log(
      `${COLOR.dim}--- batch ${doc.version} : ${doc.operations.length} operation(s) ---${COLOR.reset}`,
    );
    const result = await runBatch(db, doc, { force: flags.force });
    log(
      `${COLOR.green}✓${COLOR.reset} completed ${result.completed.length}  ${COLOR.red}✗${COLOR.reset} failed ${result.failed.length}  ${COLOR.yellow}…${COLOR.reset} skipped ${result.skipped.length}`,
    );
    for (const f of result.failed) {
      log(`  ${COLOR.red}✗${COLOR.reset} ${f.operation.src}: ${f.error}`);
    }
  } finally {
    db.close();
  }
}

function prompt(question: string): Promise<string> {
  return new Promise((resolve) => {
    process.stdout.write(question);
    const stdin = process.stdin;
    stdin.resume();
    stdin.setEncoding('utf8');
    stdin.once('data', (data) => {
      stdin.pause();
      resolve(String(data));
    });
  });
}

function usage(): void {
  log(`engram project — manage project directories across AI tools

Subcommands:
  move <src> <dst>             Move project, keep session history reachable
  archive <src>                Move to _archive/ (auto-suggests category)
  review <old> <new>           Scan for residual old-path refs, classify own/other
  undo <migration-id>          Reverse a committed migration
  list                         Show recent migrations
  recover                      Diagnose stuck / failed migrations
  move-batch <yaml>            Run multiple migrations from a YAML file

Common flags:
  -y, --yes                    Skip interactive confirmation
  -n, --dry-run                Print plan, no side effects
  --force                      Bypass git-dirty check
  --note "..."                 Audit note stored in migration_log
`);
}

async function dispatch(
  sub: string | undefined,
  rest: string[],
): Promise<void> {
  switch (sub) {
    case 'move':
      return cmdMove(rest);
    case 'archive':
      return cmdArchive(rest);
    case 'review':
      return cmdReview(rest);
    case 'undo':
      return cmdUndo(rest);
    case 'list':
      return cmdList(rest);
    case 'recover':
      return cmdRecover(rest);
    case 'move-batch':
      return cmdBatch(rest);
    case '--help':
    case '-h':
    case undefined:
      return usage();
    default:
      die(`unknown subcommand: ${sub}`);
  }
}

/**
 * Top-level try/catch — converts known errors to friendly one-line output.
 * (Codex #5 + Gemini #3): previously `main()` let exceptions escape to the
 * node unhandled-rejection path, spamming users with stack traces.
 */
export async function main(args: string[]): Promise<void> {
  try {
    await dispatch(args[0], args.slice(1));
  } catch (err) {
    const e = err as Error;
    const name = e?.name ?? 'Error';
    // Round 4: use shared retry-policy classifier so CLI error hints stay
    // consistent with MCP and HTTP. Previously CLI had its own switch
    // that drifted from the other two layers.
    const { classifyRetryPolicy } = await import(
      '../core/project-move/retry-policy.js'
    );
    const policy = classifyRetryPolicy(name);
    const retryHint =
      policy === 'safe'
        ? ' (retry is safe)'
        : policy === 'conditional'
          ? ' (retry once after resolving the condition above)'
          : policy === 'wait'
            ? ' (wait a few seconds, then retry)'
            : ''; // 'never' — no retry hint, message already explains
    switch (name) {
      case 'LockBusyError':
        console.error(
          `${COLOR.red}✗${COLOR.reset} another project-move is in progress — ${e.message}${retryHint}`,
        );
        break;
      case 'ConcurrentModificationError':
        console.error(
          `${COLOR.red}✗${COLOR.reset} a session file changed while patching; re-run \`engram project move\` to retry${retryHint}.\n   detail: ${e.message}`,
        );
        break;
      case 'InvalidUtf8Error':
        console.error(
          `${COLOR.red}✗${COLOR.reset} a session file is not valid UTF-8 — refusing to touch. Manually inspect and fix, then retry.\n   detail: ${e.message}`,
        );
        break;
      case 'DirCollisionError':
      case 'SharedEncodingCollisionError':
      case 'UndoNotAllowedError':
      case 'UndoStaleError':
        console.error(`${COLOR.red}✗${COLOR.reset} ${e.message}`);
        break;
      default: {
        // Generic: show message without stack trace
        console.error(
          `${COLOR.red}✗${COLOR.reset} ${e.message ?? String(e)}${retryHint}`,
        );
        if (process.env.ENGRAM_DEBUG) console.error(e.stack);
      }
    }
    process.exit(1);
  }
}
