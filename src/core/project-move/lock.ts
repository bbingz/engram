// src/core/project-move/lock.ts — advisory cross-process lock for project-move
//
// Purpose: prevent two `engram project move` runs from concurrently mutating
// the same filesystem + DB state. Advisory only — we cannot guarantee no
// other process (mvp.py shim, random `mv`) races with us; the DB-level
// `migration_log` pending guard (Phase 1) + per-file CAS (Phase 2) are the
// real safety nets.
//
// Protocol:
//   - Lock file: ~/.engram/.project-move.lock
//   - Contents: JSON { pid, startedAt, migrationId }
//   - Stale detection: if owning pid is gone (kill -0 fails), break lock.

import { randomUUID } from 'node:crypto';
import { link, mkdir, open, readFile, stat, unlink } from 'node:fs/promises';
import { homedir } from 'node:os';
import { dirname, join } from 'node:path';

export interface LockInfo {
  pid: number;
  startedAt: string;
  migrationId: string;
}

export class LockBusyError extends Error {
  constructor(public holder: LockInfo) {
    super(
      `project-move is already in progress (pid=${holder.pid}, migration=${holder.migrationId}, started ${holder.startedAt})`,
    );
    this.name = 'LockBusyError';
  }
}

export function defaultLockPath(home?: string): string {
  return join(home ?? homedir(), '.engram', '.project-move.lock');
}

/**
 * Try to acquire the lock. A fully written candidate is atomically linked at
 * the lock path. If the holder is stale, an inode-linked break claim ensures
 * exactly one process may remove that stale inode.
 *
 * (Codex blocker #2a): the previous read→probe→write sequence had a
 * TOCTOU window where two processes could both conclude "stale" and both
 * overwrite the lock file, each thinking they won.
 */
export async function acquireLock(
  migrationId: string,
  lockPath: string = defaultLockPath(),
): Promise<void> {
  await mkdir(dirname(lockPath), { recursive: true });
  const info: LockInfo = {
    pid: process.pid,
    startedAt: new Date().toISOString(),
    migrationId,
  };
  const payload = JSON.stringify(info, null, 2);

  // Publish a fully written inode with one atomic link. Creating lockPath and
  // filling it in separate async calls exposes a transient empty file that a
  // concurrent acquirer can misclassify as corrupt/stale and unlink.
  const candidatePath = `${lockPath}.${process.pid}.${randomUUID()}.candidate`;
  const staleBreakPath = `${lockPath}.stale-break`;
  const handle = await open(candidatePath, 'wx', 0o600);
  try {
    await handle.writeFile(payload);
  } finally {
    await handle.close();
  }

  try {
    for (let attempt = 0; attempt < 100; attempt++) {
      if (await pathExists(staleBreakPath)) {
        await new Promise((resolve) => setTimeout(resolve, 1));
        continue;
      }
      try {
        await link(candidatePath, lockPath);
        return; // acquired
      } catch (err) {
        const e = err as { code?: string };
        if (e.code !== 'EEXIST') throw err;
      }
      // EEXIST — read the holder and decide
      let holder: LockInfo | null = null;
      try {
        holder = JSON.parse(await readFile(lockPath, 'utf8')) as LockInfo;
      } catch {
        // Corrupt lock — treat as stale
      }
      if (holder && isProcessAlive(holder.pid)) {
        throw new LockBusyError(holder);
      }

      // Atomically claim this exact lock inode. A contender that read the old
      // stale bytes but arrives after a live replacement links that live inode
      // here, then the fresh PID check below prevents its removal.
      try {
        await link(lockPath, staleBreakPath);
      } catch (err) {
        const e = err as { code?: string };
        if (e.code === 'ENOENT' || e.code === 'EEXIST') continue;
        throw err;
      }
      try {
        let claimedHolder: LockInfo | null = null;
        try {
          claimedHolder = JSON.parse(
            await readFile(staleBreakPath, 'utf8'),
          ) as LockInfo;
        } catch {
          // A corrupt claimed inode is stale, but still requires identity proof.
        }
        if (claimedHolder && isProcessAlive(claimedHolder.pid)) {
          throw new LockBusyError(claimedHolder);
        }

        let stillClaimed = false;
        try {
          const [current, claimed] = await Promise.all([
            stat(lockPath),
            stat(staleBreakPath),
          ]);
          stillClaimed =
            current.dev === claimed.dev && current.ino === claimed.ino;
        } catch (err) {
          const e = err as { code?: string };
          if (e.code !== 'ENOENT') throw err;
        }
        if (!stillClaimed) continue;

        await unlink(lockPath);
        try {
          await link(candidatePath, lockPath);
          return;
        } catch (err) {
          const e = err as { code?: string };
          if (e.code !== 'EEXIST') throw err;
          // A contender may have filled the unlink/link gap. It owns the lock;
          // never remove it on behalf of this stale-break attempt.
        }
      } finally {
        await unlink(staleBreakPath).catch((err: { code?: string }) => {
          if (err.code !== 'ENOENT') throw err;
        });
      }
    }
    throw new Error(
      'acquireLock: exhausted attempts (race with another stale-break)',
    );
  } finally {
    await unlink(candidatePath).catch((err: { code?: string }) => {
      if (err.code !== 'ENOENT') throw err;
    });
  }
}

async function pathExists(path: string): Promise<boolean> {
  try {
    await stat(path);
    return true;
  } catch (err) {
    const e = err as { code?: string };
    if (e.code === 'ENOENT') return false;
    throw err;
  }
}

export async function releaseLock(
  lockPath: string = defaultLockPath(),
): Promise<void> {
  const releaseClaimPath = `${lockPath}.stale-break`;
  try {
    // Serialize release against both peer releases and stale breakers by
    // claiming this exact inode. Only the claim winner may unlink lockPath.
    await link(lockPath, releaseClaimPath);
  } catch {
    // Missing lock or another active/abandoned claim — fail closed.
    return;
  }
  try {
    const data = await readFile(releaseClaimPath, 'utf8');
    const holder = JSON.parse(data) as LockInfo;
    if (holder.pid !== process.pid) return;

    const [current, claimed] = await Promise.all([
      stat(lockPath),
      stat(releaseClaimPath),
    ]);
    if (current.dev !== claimed.dev || current.ino !== claimed.ino) return;
    await unlink(lockPath);
  } catch {
    // lock file missing or unreadable — ok, already gone
  } finally {
    await unlink(releaseClaimPath).catch(() => {});
  }
}

export async function readLock(
  lockPath: string = defaultLockPath(),
): Promise<LockInfo | null> {
  try {
    await stat(lockPath);
    const data = await readFile(lockPath, 'utf8');
    return JSON.parse(data) as LockInfo;
  } catch {
    return null;
  }
}

function isProcessAlive(pid: number): boolean {
  if (pid === process.pid) return true;
  try {
    // signal 0 = probe; throws ESRCH if process is gone
    process.kill(pid, 0);
    return true;
  } catch (err) {
    const e = err as { code?: string };
    // EPERM means process exists but we can't signal — still alive
    return e.code === 'EPERM';
  }
}
