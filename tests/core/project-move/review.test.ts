import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { reviewScan } from '../../../src/core/project-move/review.js';

/**
 * Review scan classifies residual refs into own/other per mvp.py semantics.
 * We fake `home` so getSourceRoots() rooted at the tmp dir, and populate
 * the 6 source sub-dirs with planted refs.
 */
describe('reviewScan', () => {
  let tmp: string;

  beforeEach(() => {
    tmp = mkdtempSync(join(tmpdir(), 'engram-review-'));
    // Create the 6 canonical source roots under tmp
    mkdirSync(join(tmp, '.claude', 'projects'), { recursive: true });
    mkdirSync(join(tmp, '.codex', 'sessions'), { recursive: true });
    mkdirSync(join(tmp, '.gemini', 'tmp'), { recursive: true });
    mkdirSync(join(tmp, '.local', 'share', 'opencode'), { recursive: true });
    mkdirSync(join(tmp, '.antigravity'), { recursive: true });
    mkdirSync(join(tmp, '.copilot'), { recursive: true });
  });

  afterEach(() => {
    rmSync(tmp, { recursive: true, force: true });
  });

  it('classifies CC own-dir hit as own', async () => {
    // newPath = /Users/example/-Code-/engram  →  encoded: -Users-example--Code--engram
    const ownCc = join(
      tmp,
      '.claude',
      'projects',
      '-Users-example--Code--engram',
    );
    mkdirSync(ownCc);
    writeFileSync(join(ownCc, 'x.jsonl'), '{"cwd":"/old/path"}');

    const r = await reviewScan('/old/path', {
      newPath: '/Users/example/-Code-/engram',
      home: tmp,
    });
    expect(r.own).toContain(join(ownCc, 'x.jsonl'));
    expect(r.other).toEqual([]);
  });

  it('classifies CC different-project-dir hit as other', async () => {
    // A reference inside an unrelated project's CC dir — historical, not a miss
    const otherCc = join(
      tmp,
      '.claude',
      'projects',
      '-Users-example--Code--unrelated',
    );
    mkdirSync(otherCc);
    writeFileSync(join(otherCc, 'y.jsonl'), '{"mentioned":"/old/path"}');

    const r = await reviewScan('/old/path', {
      newPath: '/Users/example/-Code-/engram',
      home: tmp,
    });
    expect(r.own).toEqual([]);
    expect(r.other).toContain(join(otherCc, 'y.jsonl'));
  });

  it('non-CC source hits always count as own (real miss needs investigation)', async () => {
    const codexFile = join(tmp, '.codex', 'sessions', 'rollout.jsonl');
    writeFileSync(codexFile, '{"cwd":"/old/path"}');

    const r = await reviewScan('/old/path', {
      newPath: '/Users/example/-Code-/engram',
      home: tmp,
    });
    expect(r.own).toContain(codexFile);
    expect(r.other).toEqual([]);
  });

  it('empty result when nothing references old path', async () => {
    writeFileSync(
      join(tmp, '.codex', 'sessions', 'rollout.jsonl'),
      '{"cwd":"/other"}',
    );
    const r = await reviewScan('/old/path', {
      newPath: '/Users/example/-Code-/engram',
      home: tmp,
    });
    expect(r.own).toEqual([]);
    expect(r.other).toEqual([]);
  });

  it('mixed: own + other hits coexist', async () => {
    const ownCc = join(
      tmp,
      '.claude',
      'projects',
      '-Users-example--Code--engram',
    );
    const otherCc = join(
      tmp,
      '.claude',
      'projects',
      '-Users-example--Code--unrelated',
    );
    mkdirSync(ownCc);
    mkdirSync(otherCc);
    writeFileSync(join(ownCc, 'a.jsonl'), '{"cwd":"/old"}');
    writeFileSync(join(otherCc, 'b.jsonl'), '{"ref":"/old"}');
    writeFileSync(join(tmp, '.codex', 'sessions', 'c.jsonl'), '{"cwd":"/old"}');

    const r = await reviewScan('/old', {
      newPath: '/Users/example/-Code-/engram',
      home: tmp,
    });
    expect(r.own.sort()).toEqual(
      [
        join(ownCc, 'a.jsonl'),
        join(tmp, '.codex', 'sessions', 'c.jsonl'),
      ].sort(),
    );
    expect(r.other).toEqual([join(otherCc, 'b.jsonl')]);
  });
});
