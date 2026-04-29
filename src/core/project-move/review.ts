// src/core/project-move/review.ts — post-move audit scan, mvp.py:review_scan
//
// Scans every source root returned by getSourceRoots() for residual
// references to the old project path. Classifies each hit as "own" (in the
// migrated project's own CC dir or a non-CC source — a real miss that needs
// investigation) vs "other" (under a DIFFERENT project's CC dir — legitimate
// historical reference, not touched by the mover).

import { relative } from 'node:path';
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

interface ReviewOptions {
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
  const ownCcDir = encodeCC(opts.newPath); // e.g. -Users-example--Code--engram

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
  }

  return {
    own: Array.from(own).sort(),
    other: Array.from(other).sort(),
  };
}
