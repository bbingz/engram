import { spawn } from 'node:child_process';
import {
  linkSync,
  mkdirSync,
  mkdtempSync,
  rmSync,
  writeFileSync,
} from 'node:fs';
import { readdir, readFile, writeFile } from 'node:fs/promises';
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

  it('concurrent owner release preserves a live hard-link replacement_repro', async () => {
    const readyPath = join(tmp, 'owner-ready');
    const startPath = join(tmp, 'owner-start');
    const replacementCandidatePath = join(tmp, 'replacement-candidate');
    const childSource = `
        import { access, writeFile } from 'node:fs/promises';
        import { acquireLock, releaseLock } from './src/core/project-move/lock.ts';

        const exists = async (path) => {
          try { await access(path); return true; } catch { return false; }
        };
        const delay = (milliseconds) => new Promise((resolve) => setTimeout(resolve, milliseconds));
        const lockPath = process.env.ENGRAM_LOCK_PATH;
        const readyPath = process.env.ENGRAM_LOCK_READY_PATH;
        const startPath = process.env.ENGRAM_LOCK_START_PATH;
        await acquireLock('old-owner', lockPath);
        await writeFile(
          lockPath,
          JSON.stringify({
            pid: process.pid,
            startedAt: new Date().toISOString(),
            migrationId: 'old-owner',
            padding: 'x'.repeat(4_000_000),
          }),
        );
        await writeFile(readyPath, 'ready');
        while (!(await exists(startPath))) await delay(1);
        await Promise.all(
          Array.from({ length: 96 }, () => releaseLock(lockPath)),
        );
      `;
    const child = spawn(
      process.execPath,
      ['--import', 'tsx', '--input-type=module', '--eval', childSource],
      {
        cwd: process.cwd(),
        env: {
          ...process.env,
          ENGRAM_LOCK_PATH: lockPath,
          ENGRAM_LOCK_READY_PATH: readyPath,
          ENGRAM_LOCK_START_PATH: startPath,
        },
      },
    );
    const completion = new Promise<void>((resolve, reject) => {
      let stderr = '';
      child.stderr.on('data', (chunk) => {
        stderr += String(chunk);
      });
      child.on('error', reject);
      child.on('exit', (code) => {
        if (code === 0) resolve();
        else reject(new Error(`release owner exited ${code}: ${stderr}`));
      });
    });

    const readyDeadline = Date.now() + 15_000;
    while (true) {
      try {
        await readFile(readyPath);
        break;
      } catch {
        if (Date.now() >= readyDeadline)
          throw new Error('release owner did not reach the start barrier');
        await new Promise((resolve) => setTimeout(resolve, 10));
      }
    }
    writeFileSync(
      replacementCandidatePath,
      JSON.stringify({
        pid: process.pid,
        startedAt: new Date().toISOString(),
        migrationId: 'live-replacement',
      }),
    );
    await writeFile(startPath, 'start');

    const publishDeadline = Date.now() + 15_000;
    while (true) {
      try {
        linkSync(replacementCandidatePath, lockPath);
        break;
      } catch (error) {
        const code = (error as { code?: string }).code;
        if (code !== 'EEXIST') throw error;
        if (Date.now() >= publishDeadline)
          throw new Error('live replacement was not published');
      }
    }
    await completion;

    const replacement = await readLock(lockPath);
    expect(replacement?.pid).toBe(process.pid);
    expect(replacement?.migrationId).toBe('live-replacement');
  }, 30_000);

  it('acquire throws LockBusyError when held by a live process', async () => {
    await acquireLock('mig-1', lockPath);
    await expect(acquireLock('mig-2', lockPath)).rejects.toThrow(LockBusyError);
  });

  it('abandoned stale-break claim fails release and acquire closed', async () => {
    await acquireLock('mig-1', lockPath);
    linkSync(lockPath, `${lockPath}.stale-break`);

    await releaseLock(lockPath);
    await expect(acquireLock('mig-2', lockPath)).rejects.toThrow(
      /exhausted attempts/,
    );
    expect((await readLock(lockPath))?.migrationId).toBe('mig-1');
    expect(await readFile(`${lockPath}.stale-break`, 'utf8')).toContain(
      'mig-1',
    );
  });

  it('concurrent acquire: exactly one winner (atomic O_EXCL)_repro', async () => {
    // Codex blocker #2a — without O_EXCL, both attempts could succeed.
    const results = await Promise.allSettled(
      Array.from({ length: 32 }, (_, index) =>
        acquireLock(`race-${index}`, lockPath),
      ),
    );
    const fulfilled = results.filter((r) => r.status === 'fulfilled').length;
    expect(fulfilled).toBe(1);
    const rejected = results.filter((r) => r.status === 'rejected');
    for (const r of rejected) {
      if (r.status === 'rejected') {
        expect(r.reason).toBeInstanceOf(LockBusyError);
      }
    }
  });

  it('multi-process stale break has exactly one winner_repro', async () => {
    const processCount = 48;
    const readyDirectory = join(tmp, 'ready');
    const startPath = join(tmp, 'start');
    const releasePath = join(tmp, 'release');
    const winnersPath = join(tmp, 'winners');
    mkdirSync(readyDirectory);
    await writeFile(
      lockPath,
      JSON.stringify({
        pid: 99999999,
        startedAt: new Date().toISOString(),
        migrationId: 'stale-holder',
        padding: 'x'.repeat(4_000_000),
      }),
    );

    const childSource = String.raw`
        import { access, appendFile, writeFile } from 'node:fs/promises';
        import { join } from 'node:path';
        import { acquireLock, releaseLock } from './src/core/project-move/lock.ts';

        const exists = async (path) => {
          try { await access(path); return true; } catch { return false; }
        };
        const delay = (milliseconds) => new Promise((resolve) => setTimeout(resolve, milliseconds));
        const id = process.env.ENGRAM_LOCK_CHILD_ID;
        const lockPath = process.env.ENGRAM_LOCK_PATH;
        const readyDirectory = process.env.ENGRAM_LOCK_READY_DIRECTORY;
        const startPath = process.env.ENGRAM_LOCK_START_PATH;
        const releasePath = process.env.ENGRAM_LOCK_RELEASE_PATH;
        const winnersPath = process.env.ENGRAM_LOCK_WINNERS_PATH;
        await writeFile(join(readyDirectory, id), 'ready');
        while (!(await exists(startPath))) await delay(1);
        try {
          await acquireLock('child-' + id, lockPath);
          await appendFile(winnersPath, id + '\n');
          while (!(await exists(releasePath))) await delay(1);
          await releaseLock(lockPath);
        } catch (error) {
          if (error?.name !== 'LockBusyError' && !String(error).includes('exhausted attempts')) {
            throw error;
          }
        }
      `;

    const completions = Array.from({ length: processCount }, (_, index) => {
      const child = spawn(
        process.execPath,
        ['--import', 'tsx', '--input-type=module', '--eval', childSource],
        {
          cwd: process.cwd(),
          env: {
            ...process.env,
            ENGRAM_LOCK_CHILD_ID: String(index),
            ENGRAM_LOCK_PATH: lockPath,
            ENGRAM_LOCK_READY_DIRECTORY: readyDirectory,
            ENGRAM_LOCK_START_PATH: startPath,
            ENGRAM_LOCK_RELEASE_PATH: releasePath,
            ENGRAM_LOCK_WINNERS_PATH: winnersPath,
          },
        },
      );
      return new Promise<void>((resolve, reject) => {
        let stderr = '';
        child.stderr.on('data', (chunk) => {
          stderr += String(chunk);
        });
        child.on('error', reject);
        child.on('exit', (code) => {
          if (code === 0) resolve();
          else
            reject(new Error(`lock child ${index} exited ${code}: ${stderr}`));
        });
      });
    });

    const deadline = Date.now() + 15_000;
    while ((await readdir(readyDirectory)).length !== processCount) {
      if (Date.now() >= deadline)
        throw new Error('lock children did not reach the start barrier');
      await new Promise((resolve) => setTimeout(resolve, 10));
    }
    await writeFile(startPath, 'start');
    await new Promise((resolve) => setTimeout(resolve, 500));
    await writeFile(releasePath, 'release');
    await Promise.all(completions);

    const winners = (await readFile(winnersPath, 'utf8'))
      .trim()
      .split('\n')
      .filter(Boolean);
    expect(winners).toHaveLength(1);
  }, 30_000);

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

  it('gitdir file with real HEAD → 归档完成', async () => {
    const src = join(tmp, 'worktree-proj');
    mkdirSync(src);
    const gitDir = join(tmp, 'linked-worktree-git');
    mkdirSync(gitDir, { recursive: true });
    writeFileSync(join(gitDir, 'HEAD'), 'ref: refs/heads/main\n');
    writeFileSync(join(src, '.git'), `gitdir: ${gitDir}\n`);
    writeFileSync(join(src, 'main.py'), 'print("hi")');

    const r = await suggestArchiveTarget(src, {
      archiveRoot: join(tmp, '_archive'),
    });

    expect(r.category).toBe('归档完成');
    expect(r.reason).toMatch(/worktree|submodule/);
  });

  it('malformed gitdir file with content → throws, user must pass --to', async () => {
    const src = join(tmp, 'malformed-worktree');
    mkdirSync(src);
    writeFileSync(join(src, '.git'), '');
    writeFileSync(join(src, 'main.py'), 'print("hi")');

    await expect(
      suggestArchiveTarget(src, { archiveRoot: join(tmp, '_archive') }),
    ).rejects.toThrow(/cannot auto-categorize|--to/);
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
