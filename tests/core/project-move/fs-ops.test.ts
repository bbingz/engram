import {
  chmodSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  statSync,
  symlinkSync,
  writeFileSync,
} from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { safeMoveDir } from '../../../src/core/project-move/fs-ops.js';

describe('safeMoveDir', () => {
  let tmp: string;

  beforeEach(() => {
    tmp = mkdtempSync(join(tmpdir(), 'engram-fsops-'));
  });

  afterEach(() => {
    rmSync(tmp, { recursive: true, force: true });
  });

  it('renames a directory on the same volume (fast path)', async () => {
    const src = join(tmp, 'proj');
    const dst = join(tmp, 'renamed');
    mkdirSync(join(src, 'sub'), { recursive: true });
    writeFileSync(join(src, 'file.txt'), 'hello');
    writeFileSync(join(src, 'sub', 'nested.txt'), 'world');

    const r = await safeMoveDir(src, dst);

    expect(r.strategy).toBe('rename');
    expect(existsSync(src)).toBe(false);
    expect(readFileSync(join(dst, 'file.txt'), 'utf8')).toBe('hello');
    expect(readFileSync(join(dst, 'sub', 'nested.txt'), 'utf8')).toBe('world');
  });

  it('preserves file mode on rename path', async () => {
    const src = join(tmp, 'proj');
    const dst = join(tmp, 'renamed');
    mkdirSync(src);
    writeFileSync(join(src, 'exec.sh'), '#!/bin/sh\n');
    chmodSync(join(src, 'exec.sh'), 0o755);

    await safeMoveDir(src, dst);

    const mode = statSync(join(dst, 'exec.sh')).mode & 0o777;
    expect(mode).toBe(0o755);
  });

  it('refuses to overwrite an existing destination', async () => {
    const src = join(tmp, 'proj');
    const dst = join(tmp, 'renamed');
    mkdirSync(src);
    mkdirSync(dst);

    await expect(safeMoveDir(src, dst)).rejects.toThrow(/already exists/);
    // src still intact
    expect(existsSync(src)).toBe(true);
  });

  it('refuses to move a symlink source (prevents chasing target)', async () => {
    const real = join(tmp, 'real');
    const link = join(tmp, 'link');
    mkdirSync(real);
    try {
      symlinkSync(real, link);
    } catch {
      // Environment without symlink permission — skip
      return;
    }
    await expect(safeMoveDir(link, join(tmp, 'dest'))).rejects.toThrow(
      /symlink/,
    );
    expect(existsSync(real)).toBe(true);
  });

  it('followSymlinks=true allows moving a symlink source', async () => {
    const real = join(tmp, 'real');
    const link = join(tmp, 'link');
    mkdirSync(real);
    writeFileSync(join(real, 'x.txt'), 'content');
    try {
      symlinkSync(real, link);
    } catch {
      return;
    }
    const r = await safeMoveDir(link, join(tmp, 'dest'), {
      followSymlinks: true,
    });
    expect(r.strategy).toBe('rename');
  });

  it('ENOENT on non-existent source', async () => {
    await expect(
      safeMoveDir(join(tmp, 'nope'), join(tmp, 'dst')),
    ).rejects.toThrow();
  });

  describe('EXDEV cross-volume fallback (mocked)', () => {
    it('falls back to copy+delete when rename throws EXDEV', async () => {
      const src = join(tmp, 'src');
      const dst = join(tmp, 'dst');
      mkdirSync(src);
      writeFileSync(join(src, 'file.txt'), 'hello');

      let renameCalls = 0;
      const r = await safeMoveDir(src, dst, {
        __fsInject: {
          rename: async (oldPath, newPath) => {
            renameCalls++;
            // First call: simulate EXDEV. Second call (tempDst → dst): real.
            if (renameCalls === 1) {
              const err = new Error(
                'EXDEV: cross-device link not permitted, simulated',
              );
              (err as Error & { code: string }).code = 'EXDEV';
              throw err;
            }
            const { rename } = await import('node:fs/promises');
            return rename(oldPath, newPath);
          },
        },
      });

      expect(r.strategy).toBe('copy-then-delete');
      expect(renameCalls).toBeGreaterThanOrEqual(2); // rename→EXDEV, tempDst→dst
      expect(existsSync(src)).toBe(false);
      expect(readFileSync(join(dst, 'file.txt'), 'utf8')).toBe('hello');
    });

    it('partial-copy failure cleans up tempDst, leaves dst untouched', async () => {
      const src = join(tmp, 'src');
      const dst = join(tmp, 'dst');
      mkdirSync(src);
      writeFileSync(join(src, 'a.txt'), 'x');

      // EXDEV on rename, then cp also fails — we should see tempDst removed
      let tempDstSeen: string | null = null;
      await expect(
        safeMoveDir(src, dst, {
          __fsInject: {
            rename: async () => {
              const err = new Error('EXDEV mock');
              (err as Error & { code: string }).code = 'EXDEV';
              throw err;
            },
            cp: async (_s, tmp) => {
              tempDstSeen = String(tmp);
              throw new Error('ENOSPC simulated');
            },
          },
        }),
      ).rejects.toThrow(/ENOSPC/);

      // dst must not exist (no clobbering) and tempDst must be absent
      expect(existsSync(dst)).toBe(false);
      if (tempDstSeen) {
        expect(existsSync(tempDstSeen)).toBe(false);
      }
      // src untouched
      expect(readFileSync(join(src, 'a.txt'), 'utf8')).toBe('x');
    });
  });
});
