// src/core/project-move/archive.ts — auto-suggest archive target per CLAUDE.md convention
//
// User convention (from /Users/example/-Code-/_项目扫描报告/CLAUDE.md):
//   _archive/历史脚本/   — YYYYMMDD- prefixed one-shot scripts
//   _archive/空项目/     — empty shells or merged-away projects
//   _archive/归档完成/   — finished projects with git history (new, 2026-04)
//
// This module suggests a target directory; the CLI asks for y/N confirmation.
// We never auto-archive — user always confirms.

import { readdir, stat } from 'node:fs/promises';
import { basename, dirname, join } from 'node:path';

export type ArchiveCategory = '历史脚本' | '空项目' | '归档完成';

/** Alias map for user input: accepts CJK names verbatim AND English
 *  aliases that appear in the MCP tool schema / Swift UI picker. Living
 *  here instead of the tools/ layer means every caller (MCP, HTTP,
 *  Swift via HTTP, CLI) shares one normalization — Round 4 Critical
 *  (reviewer C1): the HTTP layer previously passed `"archived-done"`
 *  straight through, producing `_archive/archived-done/` folders
 *  instead of `_archive/归档完成/`. */
const ARCHIVE_CATEGORY_ALIASES: Record<string, ArchiveCategory> = {
  历史脚本: '历史脚本',
  空项目: '空项目',
  归档完成: '归档完成',
  'historical-scripts': '历史脚本',
  'empty-project': '空项目',
  'archived-done': '归档完成',
  // Soft backwards-compat for early adopters (not exposed in schema enum).
  empty: '空项目',
  completed: '归档完成',
};

/** Normalize a user-supplied category string to the canonical CJK enum.
 *  Returns undefined if the input doesn't match any known alias. */
export function normalizeArchiveCategory(
  input: string | undefined,
): ArchiveCategory | undefined {
  if (!input) return undefined;
  return ARCHIVE_CATEGORY_ALIASES[input];
}

interface ArchiveSuggestion {
  /** Absolute destination path, e.g. `/Users/example/-Code-/_archive/历史脚本/WuKong` */
  dst: string;
  /** Which `_archive/<category>/` bucket */
  category: ArchiveCategory;
  /** Reason string for the user-facing confirmation prompt */
  reason: string;
}

interface ArchiveOptions {
  /** Where `_archive/` lives. Default: parent of src (e.g. `/Users/example/-Code-/_archive/`). */
  archiveRoot?: string;
  /** Skip the filesystem probe (for unit tests). */
  skipProbe?: boolean;
  /**
   * User-provided `--to` override. When set, bypass all heuristics and just
   * use this category — even if the project would otherwise be rule-4
   * (ambiguous) which normally throws. Gemini critical #1: without this
   * escape hatch, `--to` couldn't rescue ambiguous projects.
   *
   * Accepts either the canonical CJK enum OR an English alias (see
   * normalizeArchiveCategory). Non-matching strings throw.
   */
  forceCategory?: ArchiveCategory | string;
}

/**
 * Suggest an archive target for `src`. Rules match user's CLAUDE.md:
 *   1. basename starts with `YYYYMMDD-` → 历史脚本
 *   2. content is empty or only README → 空项目
 *   3. has .git and substantive files → 归档完成
 *   4. otherwise → throw, CLI must ask user for explicit --to
 */
export async function suggestArchiveTarget(
  src: string,
  opts: ArchiveOptions = {},
): Promise<ArchiveSuggestion> {
  const name = basename(src.replace(/\/+$/, ''));
  const archiveRoot =
    opts.archiveRoot ?? join(dirname(src.replace(/\/+$/, '')), '_archive');

  // User override — skip all heuristics (Gemini critical #1). Round 4
  // reviewer C1: normalize English aliases at the centralized point,
  // *not* in the tools/ layer — HTTP /api/project/archive passed raw
  // `archived-done` through and produced an English-named folder.
  if (opts.forceCategory) {
    const normalized = normalizeArchiveCategory(opts.forceCategory);
    if (!normalized) {
      throw new Error(
        `suggestArchiveTarget: unknown forceCategory '${opts.forceCategory}'. ` +
          'Expected 历史脚本 / 空项目 / 归档完成 or ' +
          'historical-scripts / empty-project / archived-done.',
      );
    }
    return {
      dst: join(archiveRoot, normalized, name),
      category: normalized,
      reason: `user-specified via --to ${normalized}`,
    };
  }

  // Rule 1: YYYYMMDD- prefix (historical one-shot scripts)
  if (/^\d{8}-/.test(name)) {
    return {
      dst: join(archiveRoot, '历史脚本', name),
      category: '历史脚本',
      reason: `basename starts with YYYYMMDD- prefix (one-shot script)`,
    };
  }

  if (opts.skipProbe) {
    // Caller doesn't want us to touch the FS — fall through to generic
    return {
      dst: join(archiveRoot, '归档完成', name),
      category: '归档完成',
      reason: 'default (probe skipped)',
    };
  }

  // Probe filesystem to distinguish empty vs substantive
  let entries: string[];
  try {
    entries = await readdir(src);
  } catch {
    throw new Error(
      `suggestArchiveTarget: cannot read ${src} — please pass --to explicitly`,
    );
  }

  const nonDotEntries = entries.filter((e) => !e.startsWith('.'));
  const hasGit = entries.includes('.git');

  // Rule 2: empty or only README
  const looksEmpty =
    nonDotEntries.length === 0 ||
    (nonDotEntries.length === 1 && /^readme/i.test(nonDotEntries[0]));
  if (looksEmpty) {
    return {
      dst: join(archiveRoot, '空项目', name),
      category: '空项目',
      reason:
        nonDotEntries.length === 0
          ? 'directory is empty'
          : 'only contains README',
    };
  }

  // Rule 3: has .git + substantive content. `.git` can be either:
  //  - a directory (normal checkout) — look for .git/HEAD
  //  - a file (worktree / submodule) — its content is `gitdir: <path>`
  // Either form counts as "has git history"; we don't need to read the file.
  if (hasGit && nonDotEntries.length > 0) {
    try {
      const gs = await stat(join(src, '.git'));
      if (gs.isDirectory()) {
        // Normal: verify .git/HEAD exists
        await stat(join(src, '.git', 'HEAD'));
      }
      // gs.isFile() counts as worktree/submodule — accept without further probe
      return {
        dst: join(archiveRoot, '归档完成', name),
        category: '归档完成',
        reason: gs.isFile()
          ? 'git worktree/submodule with substantive content'
          : 'git repository with substantive content',
      };
    } catch {
      /* .git exists but malformed; fall through */
    }
  }

  // Rule 4: ambiguous — caller must pass --to
  throw new Error(
    `suggestArchiveTarget: cannot auto-categorize ${src} ` +
      `(${nonDotEntries.length} non-dot entries, hasGit=${hasGit}). ` +
      `Please pass --to explicitly (e.g. --to 历史脚本).`,
  );
}
