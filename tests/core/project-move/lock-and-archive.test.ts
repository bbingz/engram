import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { suggestArchiveTarget } from '../../../src/core/project-move/archive.js';
import {
  acquireLock,
  LockBusyError,
  readLock,
  releaseLock,
} from '../../../src/core/project-move/lock.js';

describe('lock', () => {
  let tmp: string;
  let lockPath: string;

  beforeEach(() => {
    tmp = mkdtempSync(join(tmpdir(), 'engram-lock-'));
    lockPath = join(tmp, '.project-move.lock');
  });

  afterEach(() => {
    rmSync(tmp, { recursive: true, force: true });
  });

  it('acquire writes lock with current pid + migrationId', async () => {
    await acquireLock('mig-1', lockPath);
    const info = await readLock(lockPath);
    expect(info?.pid).toBe(process.pid);
    expect(info?.migrationId).toBe('mig-1');
  });

  it('release removes our own lock', async () => {
    await acquireLock('mig-1', lockPath);
    await releaseLock(lockPath);
    expect(await readLock(lockPath)).toBeNull();
  });

  it('release does nothing if lock belongs to another PID', async () => {
    await writeFile(
      lockPath,
      JSON.stringify({
        pid: process.pid + 99999, // unlikely to exist
        startedAt: new Date().toISOString(),
        migrationId: 'other',
      }),
    );
    await releaseLock(lockPath);
    // Stale-owner lock remains — the auto-stale logic only kicks in on acquire
    const info = await readLock(lockPath);
    expect(info).not.toBeNull();
  });

  it('acquire throws LockBusyError when held by a live process', async () => {
    await acquireLock('mig-1', lockPath);
    await expect(acquireLock('mig-2', lockPath)).rejects.toThrow(LockBusyError);
  });

  it('concurrent acquire: exactly one winner (atomic O_EXCL)', async () => {
    // Codex blocker #2a — without O_EXCL, both attempts could succeed.
    const results = await Promise.allSettled([
      acquireLock('race-a', lockPath),
      acquireLock('race-b', lockPath),
      acquireLock('race-c', lockPath),
    ]);
    const fulfilled = results.filter((r) => r.status === 'fulfilled').length;
    expect(fulfilled).toBe(1);
    const rejected = results.filter((r) => r.status === 'rejected');
    for (const r of rejected) {
      if (r.status === 'rejected') {
        expect(r.reason).toBeInstanceOf(LockBusyError);
      }
    }
  });

  it('acquire breaks stale lock when holder PID is gone', async () => {
    // Use an impossibly large PID that is certain to not exist
    await writeFile(
      lockPath,
      JSON.stringify({
        pid: 99999999,
        startedAt: new Date().toISOString(),
        migrationId: 'ghost',
      }),
    );
    await acquireLock('mig-new', lockPath); // should break the stale lock
    const info = await readLock(lockPath);
    expect(info?.migrationId).toBe('mig-new');
    expect(info?.pid).toBe(process.pid);
  });
});

describe('suggestArchiveTarget', () => {
  let tmp: string;

  beforeEach(() => {
    tmp = mkdtempSync(join(tmpdir(), 'engram-archive-'));
  });

  afterEach(() => {
    rmSync(tmp, { recursive: true, force: true });
  });

  it('YYYYMMDD- prefix → 历史脚本 (without probing)', async () => {
    const src = join(tmp, '20240630-some-script');
    mkdirSync(src);
    const r = await suggestArchiveTarget(src, {
      archiveRoot: join(tmp, '_archive'),
    });
    expect(r.category).toBe('历史脚本');
    expect(r.dst).toBe(
      join(tmp, '_archive', '历史脚本', '20240630-some-script'),
    );
  });

  it('empty directory → 空项目', async () => {
    const src = join(tmp, 'empty-proj');
    mkdirSync(src);
    const r = await suggestArchiveTarget(src, {
      archiveRoot: join(tmp, '_archive'),
    });
    expect(r.category).toBe('空项目');
  });

  it('README-only directory → 空项目', async () => {
    const src = join(tmp, 'readme-proj');
    mkdirSync(src);
    writeFileSync(join(src, 'README.md'), '# hello');
    const r = await suggestArchiveTarget(src, {
      archiveRoot: join(tmp, '_archive'),
    });
    expect(r.category).toBe('空项目');
  });

  it('git repo with content → 归档完成', async () => {
    const src = join(tmp, 'real-proj');
    mkdirSync(join(src, '.git'), { recursive: true });
    writeFileSync(join(src, '.git', 'HEAD'), 'ref: refs/heads/main\n');
    writeFileSync(join(src, 'main.py'), 'print("hi")');
    writeFileSync(join(src, 'README.md'), '# real');
    const r = await suggestArchiveTarget(src, {
      archiveRoot: join(tmp, '_archive'),
    });
    expect(r.category).toBe('归档完成');
  });

  it('ambiguous non-git with content → throws, user must pass --to', async () => {
    const src = join(tmp, 'ambiguous');
    mkdirSync(src);
    writeFileSync(join(src, 'a.txt'), 'a');
    writeFileSync(join(src, 'b.txt'), 'b');
    await expect(
      suggestArchiveTarget(src, { archiveRoot: join(tmp, '_archive') }),
    ).rejects.toThrow(/cannot auto-categorize|--to/);
  });

  it('--to override bypasses heuristic (even on otherwise-ambiguous)', async () => {
    // Gemini critical #1: same ambiguous project, but --to rescues it
    const src = join(tmp, 'ambiguous2');
    mkdirSync(src);
    writeFileSync(join(src, 'a.txt'), 'a');
    writeFileSync(join(src, 'b.txt'), 'b');
    const r = await suggestArchiveTarget(src, {
      archiveRoot: join(tmp, '_archive'),
      forceCategory: '归档完成',
    });
    expect(r.category).toBe('归档完成');
    expect(r.dst).toBe(join(tmp, '_archive', '归档完成', 'ambiguous2'));
    expect(r.reason).toMatch(/--to/);
  });
});
