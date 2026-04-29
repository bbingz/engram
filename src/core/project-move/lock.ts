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

import { mkdir, open, readFile, stat, unlink } from 'node:fs/promises';
import { homedir } from 'node:os';
import { dirname, join } from 'node:path';

interface LockInfo {
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
 * Try to acquire the lock. Atomic: uses O_EXCL ('wx' flag) so only one
 * process can create the file. If it already exists, check the holder —
 * if alive, throw LockBusyError; if stale (PID gone), remove and retry.
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

  // Up to 2 attempts: first create, if EEXIST probe holder, maybe break, retry.
  for (let attempt = 0; attempt < 2; attempt++) {
    try {
      const handle = await open(lockPath, 'wx'); // O_EXCL | O_CREAT
      try {
        await handle.writeFile(payload);
      } finally {
        await handle.close();
      }
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
    // Stale — remove and retry. unlink may race with another break attempt;
    // swallow ENOENT since that means someone already broke it.
    await unlink(lockPath).catch((err: { code?: string }) => {
      if (err.code !== 'ENOENT') throw err;
    });
    // fall through to retry open('wx')
  }
  throw new Error(
    'acquireLock: exhausted attempts (race with another stale-break)',
  );
}

export async function releaseLock(
  lockPath: string = defaultLockPath(),
): Promise<void> {
  try {
    // Only release if it's our lock — defensive against races where we
    // already broke a stale lock and the original owner came back.
    const data = await readFile(lockPath, 'utf8');
    const holder = JSON.parse(data) as LockInfo;
    if (holder.pid !== process.pid) return;
    await unlink(lockPath);
  } catch {
    // lock file missing or unreadable — ok, already gone
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
