// src/core/project-move/fs-ops.ts — physical directory move with cross-volume fallback.
//
// mvp.py uses shutil.move which silently upgrades cross-device renames to
// copy+delete. Node's fs.rename returns EXDEV instead; we have to do the
// fallback ourselves. Codex review #3 flagged that the earlier plan only
// mentioned preserveTimestamps without covering symlinks, mode bits, or
// partial-copy cleanup. This module handles all of that.

import { randomBytes } from 'node:crypto';
import {
  cp as realCp,
  lstat as realLstat,
  rename as realRename,
  rm as realRm,
  stat as realStat,
} from 'node:fs/promises';
import { dirname, join } from 'node:path';

/**
 * Injection point for tests to simulate EXDEV without two filesystems.
 * Production code uses the real fs/promises functions; tests swap `rename`
 * or `cp` to throw {code:'EXDEV'} on the first call.
 */
interface FsOpsInjection {
  rename?: typeof realRename;
  cp?: typeof realCp;
  rm?: typeof realRm;
  stat?: typeof realStat;
  lstat?: typeof realLstat;
}

interface MoveResult {
  strategy: 'rename' | 'copy-then-delete';
  bytesCopied: number;
}

interface MoveOptions {
  /** Abort if source is a symlink (we don't want to move what it points to). */
  followSymlinks?: boolean;
  /** Called on partial copy failure to allow cleanup customization. Default: rm -rf dst. */
  onPartialCopyFailure?: (dst: string, err: unknown) => Promise<void>;
  /** Test-only fs function injection. Production code omits this. */
  __fsInject?: FsOpsInjection;
}

/**
 * Move a directory from `src` to `dst`, falling back to recursive copy+delete
 * on cross-volume renames (EXDEV).
 *
 * Preserves:
 *   - File mode bits (via fs.cp on Node 20+)
 *   - Modification timestamps (preserveTimestamps: true)
 *   - Symbolic links (not dereferenced; verbatim: true equivalent)
 *
 * Errors:
 *   - src does not exist → throws with code 'ENOENT'
 *   - dst already exists → throws (refuses to overwrite; policy decision)
 *   - src is a symlink and followSymlinks is false → throws
 *   - Cross-volume copy fails mid-way → clean up dst and re-throw
 */
export async function safeMoveDir(
  src: string,
  dst: string,
  opts: MoveOptions = {},
): Promise<MoveResult> {
  const fs = {
    rename: opts.__fsInject?.rename ?? realRename,
    cp: opts.__fsInject?.cp ?? realCp,
    rm: opts.__fsInject?.rm ?? realRm,
    stat: opts.__fsInject?.stat ?? realStat,
    lstat: opts.__fsInject?.lstat ?? realLstat,
  };
  // 1. Pre-flight checks
  const srcStat = await fs.lstat(src); // lstat so symlink is detected
  if (srcStat.isSymbolicLink() && !opts.followSymlinks) {
    throw new Error(
      `safeMoveDir: source is a symlink (${src}); refusing to move the target`,
    );
  }
  try {
    await fs.stat(dst);
    throw new Error(
      `safeMoveDir: destination already exists (${dst}); refusing to overwrite`,
    );
  } catch (err) {
    if (isErrnoCode(err, 'ENOENT')) {
      // good — dst doesn't exist
    } else {
      throw err;
    }
  }

  // 2. Try the fast path: fs.rename (same-volume)
  try {
    await fs.rename(src, dst);
    return { strategy: 'rename', bytesCopied: 0 };
  } catch (err) {
    if (!isErrnoCode(err, 'EXDEV')) throw err;
    // fall through to copy+delete
  }

  // 3. Cross-volume fallback: copy to sibling temp dir first, then rename
  //    into place. Partial-copy cleanup then only touches the temp dir —
  //    never risks clobbering an existing `dst`. (Codex blocker #4.)
  const tempDst = join(
    dirname(dst),
    `.engram-move-tmp-${process.pid}-${randomBytes(3).toString('hex')}`,
  );
  let bytesCopied = 0;
  try {
    await fs.cp(src, tempDst, {
      recursive: true,
      preserveTimestamps: true,
      verbatimSymlinks: true, // don't dereference symlinks inside src
    });
    const tmpStat = await fs.stat(tempDst).catch(() => null);
    bytesCopied = tmpStat?.size ?? 0;
  } catch (err) {
    // Partial copy — wipe the temp only. dst is untouched.
    const cleanup =
      opts.onPartialCopyFailure ??
      (async (path) => {
        await fs.rm(path, { recursive: true, force: true });
      });
    await cleanup(tempDst, err).catch(() => {
      // swallow cleanup errors — original err is more informative
    });
    throw err;
  }

  // 4. Copy succeeded → promote tempDst → dst. This rename is same-volume
  //    (we copied to a sibling), so it's atomic.
  try {
    await fs.rename(tempDst, dst);
  } catch (err) {
    await fs.rm(tempDst, { recursive: true, force: true }).catch(() => {});
    throw err;
  }

  // 5. Source removed last — if this fails, dst is already in place and the
  //    caller can retry source cleanup later. We re-throw so migration_log
  //    records the issue.
  await fs.rm(src, { recursive: true });
  return { strategy: 'copy-then-delete', bytesCopied };
}

function isErrnoCode(err: unknown, code: string): boolean {
  return (
    typeof err === 'object' &&
    err !== null &&
    'code' in err &&
    (err as { code: string }).code === code
  );
}
