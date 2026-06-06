import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  symlinkSync,
  truncateSync,
  writeFileSync,
} from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { encodeCC } from '../../../src/core/project-move/encode-cc.js';
import {
  type GroupedDirReconcileResult,
  reconcileGroupedProjectDirs,
} from '../../../src/core/project-move/grouped-dir-reconcile.js';
import type { SourceRoot } from '../../../src/core/project-move/sources.js';

describe('reconcileGroupedProjectDirs', () => {
  let tmp: string;

  beforeEach(() => {
    tmp = mkdtempSync(join(tmpdir(), 'engram-grouped-reconcile-'));
  });

  afterEach(() => {
    rmSync(tmp, { recursive: true, force: true });
  });

  it('plans and applies a misencoded claude directory', async () => {
    const cwd = '/Users/bing/-Code-/CCTV_Admin';
    const root = groupedRoot('claude-code');
    const stale = join(root, '-Users-bing--Code--CCTV_Admin');
    const target = join(root, '-Users-bing--Code--CCTV-Admin');
    writeSession(stale, cwd);

    const result = await reconcileGroupedProjectDirs({
      roots: [sourceRoot('claude-code', root)],
    });

    expect(result.scannedDirs).toBe(1);
    expect(result.plannedRenames).toBe(1);
    expect(result.appliedRenames).toBe(1);
    expect(existsSync(stale)).toBe(false);
    expect(readFileSync(join(target, 'session.jsonl'), 'utf8')).toContain(cwd);
  });

  it('plans and applies a misencoded qoder directory', async () => {
    const cwd = '/Users/bing/-Code-/Service_Asset';
    const root = groupedRoot('qoder');
    const stale = join(root, '-Users-bing--Code--Service_Asset');
    const target = join(root, '-Users-bing--Code--Service-Asset');
    writeSession(stale, cwd);

    const result = await reconcileGroupedProjectDirs({
      roots: [sourceRoot('qoder', root)],
    });

    expect(result.plannedRenames).toBe(1);
    expect(result.appliedRenames).toBe(1);
    expect(existsSync(stale)).toBe(false);
    expect(existsSync(join(target, 'session.jsonl'))).toBe(true);
  });

  it('does not rename in dry-run mode', async () => {
    const cwd = '/Users/bing/-Code-/my proj';
    const root = groupedRoot('claude-code');
    const stale = join(root, '-Users-bing--Code--my proj');
    const target = join(root, '-Users-bing--Code--my-proj');
    writeSession(stale, cwd);

    const result = await reconcileGroupedProjectDirs({
      roots: [sourceRoot('claude-code', root)],
      dryRun: true,
    });

    expect(result.plannedRenames).toBe(1);
    expect(result.appliedRenames).toBe(0);
    expect(existsSync(stale)).toBe(true);
    expect(existsSync(target)).toBe(false);
  });

  it('skips target collisions', async () => {
    const cwd = '/Users/bing/-Code-/CCTV_Admin';
    const root = groupedRoot('claude-code');
    const stale = join(root, '-Users-bing--Code--CCTV_Admin');
    const target = join(root, '-Users-bing--Code--CCTV-Admin');
    writeSession(stale, cwd);
    mkdirSync(target);

    const result = await reconcileGroupedProjectDirs({
      roots: [sourceRoot('claude-code', root)],
    });

    expect(result.collisions).toBe(1);
    expect(result.appliedRenames).toBe(0);
    expect(existsSync(stale)).toBe(true);
    expect(existsSync(target)).toBe(true);
  });

  it('counts a collision when the target appears after dry-run planning', async () => {
    const cwd = '/Users/bing/-Code-/CCTV_Admin';
    const root = groupedRoot('claude-code');
    const stale = join(root, '-Users-bing--Code--CCTV_Admin');
    const target = join(root, '-Users-bing--Code--CCTV-Admin');
    writeSession(stale, cwd);

    const dryRun = await reconcileGroupedProjectDirs({
      roots: [sourceRoot('claude-code', root)],
      dryRun: true,
    });
    expect(dryRun.plannedRenames).toBe(1);

    mkdirSync(target);
    const result = await reconcileGroupedProjectDirs({
      roots: [sourceRoot('claude-code', root)],
    });

    expect(result.collisions).toBe(1);
    expect(result.appliedRenames).toBe(0);
    expect(existsSync(stale)).toBe(true);
  });

  it('skips ambiguous directories', async () => {
    const root = groupedRoot('claude-code');
    const stale = join(root, '-Users-bing--Code--mixed');
    writeSessionLines(stale, [
      '{"cwd":"/Users/bing/-Code-/CCTV_Admin"}',
      '{"payload":{"cwd":"/Users/bing/-Code-/Service_Asset"}}',
    ]);

    const result = await reconcileGroupedProjectDirs({
      roots: [sourceRoot('claude-code', root)],
    });

    expect(result.ambiguous).toBe(1);
    expect(result.plannedRenames).toBe(0);
    expect(existsSync(stale)).toBe(true);
  });

  it('skips already-correct directories', async () => {
    const cwd = '/Users/bing/-Code-/CCTV_Admin';
    const root = groupedRoot('claude-code');
    const correct = join(root, encodeCC(cwd));
    writeSession(correct, cwd);

    const result = await reconcileGroupedProjectDirs({
      roots: [sourceRoot('claude-code', root)],
    });

    expect(result.scannedDirs).toBe(1);
    expect(result.plannedRenames).toBe(0);
    expect(result.appliedRenames).toBe(0);
    expect(existsSync(correct)).toBe(true);
  });

  it('skips immediate child symlinks', async () => {
    const cwd = '/Users/bing/-Code-/CCTV_Admin';
    const root = groupedRoot('claude-code');
    const real = join(tmp, 'real-child');
    writeSession(real, cwd);
    try {
      symlinkSync(real, join(root, '-Users-bing--Code--CCTV_Admin'), 'dir');
    } catch {
      return;
    }

    const result = await reconcileGroupedProjectDirs({
      roots: [sourceRoot('claude-code', root)],
    });

    expect(result.scannedDirs).toBe(0);
    expect(result.plannedRenames).toBe(0);
  });

  it('does not use nested symlinks for cwd evidence', async () => {
    const cwd = '/Users/bing/-Code-/CCTV_Admin';
    const root = groupedRoot('claude-code');
    const stale = join(root, '-Users-bing--Code--CCTV_Admin');
    const real = join(tmp, 'real-nested');
    mkdirSync(stale);
    writeSession(real, cwd);
    try {
      symlinkSync(real, join(stale, 'nested'), 'dir');
    } catch {
      return;
    }

    const result = await reconcileGroupedProjectDirs({
      roots: [sourceRoot('claude-code', root)],
    });

    expect(result.scannedDirs).toBe(1);
    expect(result.plannedRenames).toBe(0);
    expect(existsSync(stale)).toBe(true);
  });

  it('skips oversized files', async () => {
    const cwd = '/Users/bing/-Code-/CCTV_Admin';
    const root = groupedRoot('claude-code');
    const stale = join(root, '-Users-bing--Code--CCTV_Admin');
    mkdirSync(stale);
    const session = join(stale, 'session.jsonl');
    writeFileSync(session, `${JSON.stringify({ cwd })}\n`);
    truncateSync(session, 50 * 1024 * 1024 + 1);

    const result = await reconcileGroupedProjectDirs({
      roots: [sourceRoot('claude-code', root)],
    });

    expect(result.issues).toBe(1);
    expect(result.plannedRenames).toBe(0);
    expect(existsSync(stale)).toBe(true);
  });

  it('returns zero counts for missing roots', async () => {
    const result = await reconcileGroupedProjectDirs({
      roots: [sourceRoot('claude-code', join(tmp, 'missing'))],
    });

    expect(result).toEqual({
      scannedDirs: 0,
      plannedRenames: 0,
      appliedRenames: 0,
      collisions: 0,
      ambiguous: 0,
      issues: 0,
    } satisfies GroupedDirReconcileResult);
  });

  function groupedRoot(id: 'claude-code' | 'qoder') {
    const root = join(tmp, id);
    mkdirSync(root, { recursive: true });
    return root;
  }

  function sourceRoot(id: 'claude-code' | 'qoder', path: string): SourceRoot {
    return { id, path, encodeProjectDir: encodeCC };
  }

  function writeSession(dir: string, cwd: string) {
    writeSessionLines(dir, [JSON.stringify({ cwd })]);
  }

  function writeSessionLines(dir: string, lines: string[]) {
    mkdirSync(dir, { recursive: true });
    writeFileSync(join(dir, 'session.jsonl'), `${lines.join('\n')}\n`);
  }
});
