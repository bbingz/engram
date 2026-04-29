import {
  mkdirSync,
  mkdtempSync,
  rmSync,
  symlinkSync,
  writeFileSync,
} from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import {
  encodeIflow,
  encodePi,
  findReferencingFiles,
  getSourceRoots,
  type WalkIssue,
  walkSessionFiles,
} from '../../../src/core/project-move/sources.js';

describe('getSourceRoots', () => {
  it('returns the 8 canonical AI session roots (includes pi)', () => {
    const roots = getSourceRoots('/home/test');
    const ids = roots.map((r) => r.id);
    expect(ids).toEqual([
      'claude-code',
      'codex',
      'gemini-cli',
      'iflow',
      'pi',
      'opencode',
      'antigravity',
      'copilot',
    ]);
    // copilot root must match mvp.py COPILOT_DATA
    expect(roots.find((r) => r.id === 'copilot')?.path).toBe(
      '/home/test/.copilot',
    );
    expect(roots.find((r) => r.id === 'iflow')?.path).toBe(
      '/home/test/.iflow/projects',
    );
    expect(roots.find((r) => r.id === 'pi')?.path).toBe(
      '/home/test/.pi/agent/sessions',
    );
  });

  it('encodeProjectDir is set exactly for sources with project-grouped dirs', () => {
    const roots = getSourceRoots('/h');
    const withEncoder = roots
      .filter((r) => r.encodeProjectDir !== null)
      .map((r) => r.id);
    expect(withEncoder).toEqual(['claude-code', 'gemini-cli', 'iflow', 'pi']);
    // Spot check each encoding rule.
    const ccRoot = roots.find((r) => r.id === 'claude-code');
    expect(ccRoot?.encodeProjectDir?.('/Users/a/b/proj')).toBe(
      '-Users-a-b-proj',
    );
    const geminiRoot = roots.find((r) => r.id === 'gemini-cli');
    expect(geminiRoot?.encodeProjectDir?.('/Users/a/b/proj')).toBe('proj');
    const iflowRoot = roots.find((r) => r.id === 'iflow');
    expect(iflowRoot?.encodeProjectDir?.('/Users/a/b/proj')).toBe(
      '-Users-a-b-proj',
    );
    const piRoot = roots.find((r) => r.id === 'pi');
    expect(piRoot?.encodeProjectDir?.('/Users/a/b/proj')).toBe(
      '--Users-a-b-proj--',
    );
  });
});

describe('encodePi', () => {
  it('mirrors Pi CLI session directory encoding', () => {
    expect(encodePi('/Users/example/-Code-/polycli')).toBe(
      '--Users-example--Code--polycli--',
    );
  });
});

describe('encodeIflow', () => {
  it('mirrors iFlow CLI: strips leading/trailing dashes per segment', () => {
    // Real observed cases on dev machine:
    expect(encodeIflow('/Users/example/-Code-/coding-memory')).toBe(
      '-Users-example-Code-coding-memory',
    );
    expect(encodeIflow('/Users/example/-Code-/engram')).toBe(
      '-Users-example-Code-engram',
    );
    expect(encodeIflow('/Users/example/-Code-/WebSite_GLM')).toBe(
      '-Users-example-Code-WebSite_GLM',
    );
  });
});

describe('walkSessionFiles + findReferencingFiles', () => {
  let tmp: string;

  beforeEach(() => {
    tmp = mkdtempSync(join(tmpdir(), 'engram-sources-'));
  });

  afterEach(() => {
    rmSync(tmp, { recursive: true });
  });

  it('yields .jsonl and .json files, skips other extensions', async () => {
    writeFileSync(join(tmp, 'session.jsonl'), 'x');
    writeFileSync(join(tmp, 'config.json'), 'x');
    writeFileSync(join(tmp, 'readme.md'), 'x');
    writeFileSync(join(tmp, 'binary.bin'), 'x');

    const seen: string[] = [];
    for await (const f of walkSessionFiles(tmp)) seen.push(f);
    expect(seen.sort()).toEqual(
      [join(tmp, 'config.json'), join(tmp, 'session.jsonl')].sort(),
    );
  });

  it('recurses into subdirectories', async () => {
    mkdirSync(join(tmp, 'sub', 'deep'), { recursive: true });
    writeFileSync(join(tmp, 'sub', 'deep', 'x.jsonl'), 'x');

    const seen: string[] = [];
    for await (const f of walkSessionFiles(tmp)) seen.push(f);
    expect(seen).toEqual([join(tmp, 'sub', 'deep', 'x.jsonl')]);
  });

  it('does NOT follow symlinks', async () => {
    mkdirSync(join(tmp, 'real'));
    writeFileSync(join(tmp, 'real', 'x.jsonl'), 'x');
    try {
      symlinkSync(join(tmp, 'real'), join(tmp, 'link'));
    } catch {
      // may not have symlink permissions in some test environments — skip
      return;
    }
    const seen: string[] = [];
    for await (const f of walkSessionFiles(tmp)) seen.push(f);
    expect(seen).toEqual([join(tmp, 'real', 'x.jsonl')]);
  });

  it('silently returns for non-existent root', async () => {
    const seen: string[] = [];
    for await (const f of walkSessionFiles('/does/not/exist/at/all')) {
      seen.push(f);
    }
    expect(seen).toEqual([]);
  });

  it('findReferencingFiles matches literal byte substring', async () => {
    writeFileSync(join(tmp, 'a.jsonl'), '{"cwd":"/Users/example/foo"}');
    writeFileSync(join(tmp, 'b.jsonl'), '{"cwd":"/Users/example/bar"}');
    writeFileSync(join(tmp, 'c.jsonl'), 'nothing interesting');

    const hits = await findReferencingFiles(tmp, '/Users/example/foo');
    expect(hits).toEqual([join(tmp, 'a.jsonl')]);
  });

  it('findReferencingFiles handles UTF-8 needles', async () => {
    writeFileSync(join(tmp, 'a.jsonl'), '{"cwd":"/项目/旧"}');
    writeFileSync(join(tmp, 'b.jsonl'), '{"cwd":"/other"}');

    const hits = await findReferencingFiles(tmp, '/项目/旧');
    expect(hits).toEqual([join(tmp, 'a.jsonl')]);
  });

  it('findReferencingFiles returns empty for empty needle', async () => {
    writeFileSync(join(tmp, 'a.jsonl'), 'x');
    expect(await findReferencingFiles(tmp, '')).toEqual([]);
  });

  it('findReferencingFiles grep fast-path + walk fallback give same result', async () => {
    mkdirSync(join(tmp, 'sub'));
    writeFileSync(join(tmp, 'a.jsonl'), '{"cwd":"/proj/alpha"}');
    writeFileSync(join(tmp, 'sub', 'b.jsonl'), '{"cwd":"/proj/alpha"}');
    writeFileSync(join(tmp, 'c.jsonl'), '{"cwd":"/proj/beta"}');

    const hits = await findReferencingFiles(tmp, '/proj/alpha');
    expect(hits.sort()).toEqual(
      [join(tmp, 'a.jsonl'), join(tmp, 'sub', 'b.jsonl')].sort(),
    );
  });

  it('findReferencingFiles returns empty for non-existent root', async () => {
    expect(
      await findReferencingFiles('/does/not/exist/engram-test', '/any'),
    ).toEqual([]);
  });

  it('walkSessionFiles reports too-large files via onIssue (Gemini major #4)', async () => {
    writeFileSync(join(tmp, 'small.jsonl'), 'x');
    writeFileSync(join(tmp, 'big.jsonl'), 'x'.repeat(100));

    const issues: WalkIssue[] = [];
    const seen: string[] = [];
    for await (const f of walkSessionFiles(tmp, {
      maxFileBytes: 10,
      onIssue: (i) => issues.push(i),
    })) {
      seen.push(f);
    }
    expect(seen).toEqual([join(tmp, 'small.jsonl')]);
    expect(issues).toHaveLength(1);
    expect(issues[0].path).toBe(join(tmp, 'big.jsonl'));
    expect(issues[0].reason).toBe('too_large');
  });

  it('walkSessionFiles reports symlinks via onIssue (not silently dropped)', async () => {
    mkdirSync(join(tmp, 'real'));
    writeFileSync(join(tmp, 'real', 'x.jsonl'), 'x');
    try {
      symlinkSync(join(tmp, 'real', 'x.jsonl'), join(tmp, 'link.jsonl'));
    } catch {
      return; // symlink not supported
    }

    const issues: WalkIssue[] = [];
    for await (const _ of walkSessionFiles(tmp, {
      onIssue: (i) => issues.push(i),
    })) {
      /* consume */
    }
    const symlinkIssue = issues.find((i) => i.reason === 'skipped_symlink');
    expect(symlinkIssue).toBeDefined();
    expect(symlinkIssue?.path).toBe(join(tmp, 'link.jsonl'));
  });
});
