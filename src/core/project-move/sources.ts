// src/core/project-move/sources.ts — enumerate the AI session root dirs
// that a project move must scan + patch.
//
// Mirrors mvp.py globals (CC_PROJECTS, CODEX_SESSIONS, GEMINI_TMP,
// OPENCODE_DATA, ANTIGRAVITY_DATA, COPILOT_DATA). Codex review #7 flagged
// the earlier plan's "5 sources" as a static regression; this module is the
// single source of truth.

import { execFile } from 'node:child_process';
import type { Dirent } from 'node:fs';
import { readdir, stat } from 'node:fs/promises';
import { homedir } from 'node:os';
import { basename, join } from 'node:path';
import { promisify } from 'node:util';
import { encodeCC } from './encode-cc.js';

const execFileAsync = promisify(execFile);

/**
 * Encode a project cwd into the iFlow-style project directory name.
 *
 * iFlow's scheme: join segments with `-`, stripping leading/trailing
 * dashes from each segment first. Lossy for paths with `-` wrappers
 * (e.g. `/Users/example/-Code-/coding-memory` → `-Users-example-Code-coding-memory`,
 * not the CC-style `-Users-example--Code--coding-memory`).
 *
 * **FOOTGUN (Codex MAJOR #3 + Gemini MAJOR #2)**: different paths can collapse
 * to the same encoded name — e.g. `/a/-foo-/p` and `/a/foo/p` both encode to
 * `-a-foo-p`. The project-move orchestrator does a pre-flight stat on the
 * target dir, so it *fails fast* instead of overwriting another project's
 * sessions, but the collision itself requires manual intervention (move
 * the target aside, or migrate the colliding projects one at a time).
 *
 * Observed convention (tests: `-Users-example-Code-coding-memory`, `-Users-example-Code-WebSite_GLM`).
 */
export function encodeIflow(abs: string): string {
  return abs
    .split('/')
    .map((seg) => seg.replace(/^-+/, '').replace(/-+$/, ''))
    .join('-');
}

export function encodePi(abs: string): string {
  return `--${abs.replace(/^[/\\]/, '').replace(/[/\\:]/g, '-')}--`;
}

export type SourceId =
  | 'claude-code'
  | 'codex'
  | 'gemini-cli'
  | 'pi'
  | 'opencode'
  | 'antigravity'
  | 'copilot'
  | 'iflow';

interface SourceRoot {
  /** Stable identifier used in logs / audit output. */
  id: SourceId;
  /** Absolute filesystem path of the root directory. */
  path: string;
  /** Encode a project cwd into the per-project directory name under `path`.
   *  Return null to opt out of directory-rename (flat-layout sources store
   *  sessions alongside each other without project grouping — patching
   *  file contents is the only work needed). */
  encodeProjectDir: ((cwd: string) => string) | null;
}

/**
 * The session root directories a project move must consider.
 * Returns absolute paths rooted at `home` (default: homedir()).
 *
 * Ordering: the first five (claude-code, codex, gemini-cli, iflow, pi) are
 * known-active sources on this machine; the final three (opencode,
 * antigravity, copilot) are here for compatibility with mvp.py's scan.
 */
export function getSourceRoots(home?: string): SourceRoot[] {
  const h = home ?? homedir();
  return [
    {
      id: 'claude-code',
      path: join(h, '.claude', 'projects'),
      encodeProjectDir: encodeCC,
    },
    {
      id: 'codex',
      path: join(h, '.codex', 'sessions'),
      encodeProjectDir: null, // flat: date-based subdirs, no per-project grouping
    },
    {
      id: 'gemini-cli',
      path: join(h, '.gemini', 'tmp'),
      // Gemini's tmp/ groups chats under <basename(cwd)>/. Sharp edge:
      // two projects with the same basename collide in one dir. Accepting
      // the risk (mvp.py never handled this either).
      encodeProjectDir: basename,
    },
    {
      id: 'iflow',
      path: join(h, '.iflow', 'projects'),
      encodeProjectDir: encodeIflow,
    },
    {
      id: 'pi',
      path: join(h, '.pi', 'agent', 'sessions'),
      encodeProjectDir: encodePi,
    },
    {
      id: 'opencode',
      path: join(h, '.local', 'share', 'opencode'),
      encodeProjectDir: null,
    },
    {
      id: 'antigravity',
      path: join(h, '.antigravity'),
      encodeProjectDir: null,
    },
    {
      id: 'copilot',
      path: join(h, '.copilot'),
      encodeProjectDir: null,
    },
  ];
}

/**
 * Error reported back to the caller from walkSessionFiles (Gemini major #4):
 * individual EACCES / ENOENT / too-large-file events shouldn't crash the
 * scan, but shouldn't be silent either — the caller (project-move
 * orchestrator) should surface them into migration_log.audit_note so users
 * know which files their migration skipped.
 */
export interface WalkIssue {
  path: string;
  reason:
    | 'readdir_failed'
    | 'stat_failed'
    | 'too_large'
    | 'skipped_symlink'
    | 'skipped_wrong_ext';
  detail?: string;
}

/**
 * Recursively walk `root` and yield file paths. Issues (errors + skips)
 * are collected on `onIssue` for caller inspection — never silently lost.
 *
 * Skips: symlinks (never followed), directories we can't read, files
 * larger than limit, files whose extension isn't in the set.
 * Does NOT skip hidden directories — `.engram/`, `.claude/tasks/` etc
 * are legitimate AI session stores.
 *
 * Uses a LIFO stack (pop) not a FIFO queue (shift) — shift is O(n) on arrays,
 * pop is O(1). Traversal order is irrelevant (we scan everything).
 */
export async function* walkSessionFiles(
  root: string,
  opts: {
    extensions?: Set<string>;
    maxFileBytes?: number;
    onIssue?: (issue: WalkIssue) => void;
  } = {},
): AsyncGenerator<string> {
  const exts = opts.extensions ?? new Set(['.jsonl', '.json']);
  const maxBytes = opts.maxFileBytes ?? 128 * 1024 * 1024;
  const report = opts.onIssue ?? (() => {});
  try {
    await stat(root);
  } catch {
    return; // root doesn't exist — caller expects silent empty yield
  }

  const stack: string[] = [root];
  while (stack.length > 0) {
    const dir = stack.pop() as string;
    let entries: Dirent[];
    try {
      entries = (await readdir(dir, { withFileTypes: true })) as Dirent[];
    } catch (err) {
      report({
        path: dir,
        reason: 'readdir_failed',
        detail: (err as Error).message,
      });
      continue;
    }
    for (const entry of entries) {
      const name =
        typeof entry.name === 'string' ? entry.name : String(entry.name);
      const full = join(dir, name);
      if (entry.isSymbolicLink()) {
        report({ path: full, reason: 'skipped_symlink' });
        continue;
      }
      if (entry.isDirectory()) {
        stack.push(full);
        continue;
      }
      if (!entry.isFile()) continue;
      const dot = name.lastIndexOf('.');
      if (dot < 0) continue;
      const ext = name.slice(dot);
      if (!exts.has(ext)) continue; // not an error — just not a session file
      let fileStat: Awaited<ReturnType<typeof stat>>;
      try {
        fileStat = await stat(full);
      } catch (err) {
        report({
          path: full,
          reason: 'stat_failed',
          detail: (err as Error).message,
        });
        continue;
      }
      if (fileStat.size > maxBytes) {
        report({
          path: full,
          reason: 'too_large',
          detail: `size=${fileStat.size}, limit=${maxBytes}`,
        });
        continue;
      }
      yield full;
    }
  }
}

/**
 * Find JSONL/JSON files under `root` that contain `needle` as a literal
 * byte substring. Mirrors `mvp.py:grep_files`.
 *
 * Performance (Gemini blocker #3): 10万+ file trees would be seconds-slow
 * with pure TS walk. Prefer subprocess `grep -rlF` when available — ~100x
 * faster and exactly what mvp.py used. Falls back to TS walk on platforms
 * without grep (unlikely on macOS/Linux; Windows via WSL if applicable).
 */
export async function findReferencingFiles(
  root: string,
  needle: string,
): Promise<string[]> {
  if (!needle) return [];
  try {
    await stat(root);
  } catch {
    return []; // root doesn't exist
  }
  const viaGrep = await tryGrepFastPath(root, needle);
  if (viaGrep !== null) return viaGrep;
  return await walkAndGrepFallback(root, needle);
}

/**
 * Fast path: `grep -rlF --include=*.jsonl --include=*.json <needle> <root>`.
 * Returns null on any grep failure (not found, permission, unknown flag)
 * so the caller falls back to the TS walk. Returns [] on "no matches" —
 * grep exits with code 1 for zero matches; we treat that as success.
 */
async function tryGrepFastPath(
  root: string,
  needle: string,
): Promise<string[] | null> {
  try {
    const { stdout } = await execFileAsync(
      'grep',
      [
        '-rlF',
        '--include=*.jsonl',
        '--include=*.json',
        '--', // end of options (safety; `needle` may start with `-`)
        needle,
        root,
      ],
      { maxBuffer: 32 * 1024 * 1024 },
    );
    return stdout
      .split('\n')
      .map((s) => s.trim())
      .filter((s) => s.length > 0);
  } catch (err) {
    // grep exits 1 when no matches — stdout is empty, stderr is empty.
    // execFile throws on non-zero exit; inspect and distinguish.
    const e = err as { code?: number; stdout?: string; stderr?: string };
    if (e.code === 1 && !e.stderr) return [];
    // Any other failure (grep missing, permission, etc.) — fall back
    return null;
  }
}

async function walkAndGrepFallback(
  root: string,
  needle: string,
): Promise<string[]> {
  const { readFile } = await import('node:fs/promises');
  const hits: string[] = [];
  const needleBuf = Buffer.from(needle, 'utf8');
  for await (const filePath of walkSessionFiles(root)) {
    try {
      const buf = await readFile(filePath);
      if (buf.indexOf(needleBuf) !== -1) hits.push(filePath);
    } catch {
      // unreadable — skip (tracked at higher level via walk errors)
    }
  }
  return hits;
}
