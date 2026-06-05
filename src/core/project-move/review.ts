// src/core/project-move/review.ts — post-move audit scan, mvp.py:review_scan
//
// Scans every source root returned by getSourceRoots() for residual
// references to the old project path. Classifies each hit as "own" (in the
// migrated project's own CC dir or a non-CC source — a real miss that needs
// investigation) vs "other" (under a DIFFERENT project's CC dir — legitimate
// historical reference, not touched by the mover).

import { existsSync } from 'node:fs';
import { join, relative } from 'node:path';
import BetterSqlite3, { type Database as SqliteDatabase } from 'better-sqlite3';
import { encodeCC } from './encode-cc.js';
import { findReferencingFiles, getSourceRoots } from './sources.js';

export interface ReviewResult {
  /** Files under the migrated project's own space still referencing old path.
   *  These are real leftovers — auto-fix attempts (`."` sentence-end) should
   *  target these first. After a fix, rescan — any remaining own = manual. */
  own: string[];
  /** Files in unrelated conversations that mention old path as context.
   *  Left alone by design — they are historical records, not live refs. */
  other: string[];
}

export interface ReviewOptions {
  /** Where the `new` path now lives, for computing the own-scope CC dir. */
  newPath: string;
  /** Override for tests — defaults to getSourceRoots() (uses homedir). */
  home?: string;
}

/**
 * Scan all configured sources for residual `old` references and classify.
 *
 * Own-scope rules:
 *   - Any hit NOT under the Claude Code source root → "own"
 *   - Under CC root, in the migrated project's own encoded-cwd dir → "own"
 *   - Under CC root, in a DIFFERENT project's dir → "other"
 *
 * This mirrors mvp.py:review_scan exactly.
 */
export async function reviewScan(
  oldPath: string,
  opts: ReviewOptions,
): Promise<ReviewResult> {
  const roots = getSourceRoots(opts.home);
  const ccRoot = roots.find((r) => r.id === 'claude-code')?.path;
  const ownCcDir = encodeCC(opts.newPath); // e.g. -Users-bing--Code--engram

  const own = new Set<string>();
  const other = new Set<string>();

  for (const root of roots) {
    const hits = await findReferencingFiles(root.path, oldPath);
    for (const hit of hits) {
      let isOther = false;
      if (ccRoot) {
        const rel = relative(ccRoot, hit);
        if (!rel.startsWith('..') && rel !== hit) {
          // Path is under ccRoot. First segment is the encoded project dir.
          const firstSeg = rel.split('/')[0];
          if (firstSeg !== ownCcDir) isOther = true;
        }
      }
      (isOther ? other : own).add(hit);
    }
    if (root.id === 'opencode') {
      for (const hit of findOpenCodeResidualReferences(root.path, oldPath)) {
        own.add(hit);
      }
    }
  }

  return {
    own: Array.from(own).sort(),
    other: Array.from(other).sort(),
  };
}

function findOpenCodeResidualReferences(
  root: string,
  oldPath: string,
): string[] {
  const dbPath = join(root, 'opencode.db');
  if (!existsSync(dbPath)) return [];
  const sqlite = new BetterSqlite3(dbPath, { readonly: true });
  try {
    if (!hasOpenCodeSessionDirectory(sqlite)) return [];
    const variants = pathVariants(oldPath);
    const rows = sqlite
      .prepare(
        `
        SELECT id, directory FROM session
        WHERE directory IN (?, ?, ?)
          OR substr(directory, 1, length(?)) = ?
          OR substr(directory, 1, length(?)) = ?
          OR substr(directory, 1, length(?)) = ?
        ORDER BY id
        `,
      )
      .all(
        variants[0],
        variants[1],
        variants[2],
        `${variants[0]}/`,
        `${variants[0]}/`,
        `${variants[1]}/`,
        `${variants[1]}/`,
        `${variants[2]}/`,
        `${variants[2]}/`,
      ) as Array<{ id: string; directory: string }>;
    return rows
      .filter((row) => matchingPrefix(row.directory, variants))
      .map((row) => `${dbPath}::session:${row.id}:directory`);
  } catch {
    return [];
  } finally {
    sqlite.close();
  }
}

function hasOpenCodeSessionDirectory(sqlite: SqliteDatabase): boolean {
  const table = sqlite
    .prepare(
      "SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'session') AS present",
    )
    .get() as { present: number } | undefined;
  if (table?.present !== 1) return false;
  const columns = sqlite.prepare('PRAGMA table_info(session)').all() as Array<{
    name: string;
  }>;
  const names = new Set(columns.map((column) => column.name));
  return names.has('id') && names.has('directory');
}

function pathVariants(path: string): [string, string, string] {
  const variants = Array.from(
    new Set([path, path.normalize('NFC'), path.normalize('NFD')]),
  );
  while (variants.length < 3) variants.push(variants[0]);
  return variants as [string, string, string];
}

function matchingPrefix(directory: string, variants: string[]): boolean {
  return variants.some(
    (variant) => directory === variant || directory.startsWith(`${variant}/`),
  );
}
