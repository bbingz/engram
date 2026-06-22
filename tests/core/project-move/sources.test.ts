import {
  mkdirSync,
  mkdtempSync,
  rmSync,
  symlinkSync,
  truncateSync,
  writeFileSync,
} from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import {
  encodeGemini,
  encodeIflow,
  findReferencingFiles,
  getSourceRoots,
  type WalkIssue,
  walkSessionFiles,
} from '../../../src/core/project-move/sources.js';

describe('getSourceRoots', () => {
  it('returns the canonical AI session roots, including all Codex stores', () => {
    const roots = getSourceRoots('/home/test');
    const ids = roots.map((r) => r.id);
    expect(ids).toEqual([
      'claude-code',
      'codex',
      'codex-archived',
      'codex-rollout-summaries',
      'gemini-cli',
      'iflow',
      'qoder',
      'opencode',
      'antigravity',
      'antigravity-legacy',
      'commandcode',
      'copilot',
    ]);
    // copilot root must match mvp.py COPILOT_DATA
    expect(roots.find((r) => r.id === 'copilot')?.path).toBe(
      '/home/test/.copilot',
    );
    expect(roots.find((r) => r.id === 'codex-archived')?.path).toBe(
      '/home/test/.codex/archived_sessions',
    );
    expect(roots.find((r) => r.id === 'codex-rollout-summaries')?.path).toBe(
      '/home/test/.codex/memories/rollout_summaries',
    );
    expect(roots.find((r) => r.id === 'iflow')?.path).toBe(
      '/home/test/.iflow/projects',
    );
    expect(roots.find((r) => r.id === 'qoder')?.path).toBe(
      '/home/test/.qoder/projects',
    );
    expect(roots.find((r) => r.id === 'commandcode')?.path).toBe(
      '/home/test/.commandcode/projects',
    );
    expect(roots.find((r) => r.id === 'antigravity')?.path).toBe(
      '/home/test/.gemini/antigravity-cli/brain',
    );
    expect(roots.find((r) => r.id === 'antigravity-legacy')?.path).toBe(
      '/home/test/.gemini/antigravity',
    );
  });

  it('encodeProjectDir is set exactly for sources with project-grouped dirs', () => {
    const roots = getSourceRoots('/h');
    const withEncoder = roots
      .filter((r) => r.encodeProjectDir !== null)
      .map((r) => r.id);
    expect(withEncoder).toEqual([
      'claude-code',
      'gemini-cli',
      'iflow',
      'qoder',
    ]);
    // Spot check each encoding rule.
    const ccRoot = roots.find((r) => r.id === 'claude-code');
    expect(ccRoot?.encodeProjectDir?.('/Users/a/b/proj')).toBe(
      '-Users-a-b-proj',
    );
    const geminiRoot = roots.find((r) => r.id === 'gemini-cli');
    expect(geminiRoot?.encodeProjectDir?.('/Users/a/b/proj')).toBe(
      'fb8ca3065078b192b450d6b162f97aea0d9af077c3eae1fc83efe185896b8be4',
    );
    expect(geminiRoot?.encodeProjectDir?.('/Users/bing/-Code-')).toBe(
      'f2b35ab42fab408079d691fc1e4b5fcc3721611ee3fc5a01e5d295dadfd4a01e',
    );
    expect(
      geminiRoot?.encodeProjectDir?.('/Users/bing/-Code-/WebSite_Gemini'),
    ).toBe('14c0b06be029ed0eec4a9c32d825e06252ec7b3893898df56a8891dba6fdebf2');
    expect(
      geminiRoot?.encodeProjectDir?.('/Users/bing/-Code-/java_charge'),
    ).toBe('5f3981f56dac06ba6e0042d1c632b29de18c0ef9d2715d005e4fb5090c9f0644');
    const iflowRoot = roots.find((r) => r.id === 'iflow');
    expect(iflowRoot?.encodeProjectDir?.('/Users/a/b/proj')).toBe(
      '-Users-a-b-proj',
    );
    const qoderRoot = roots.find((r) => r.id === 'qoder');
    expect(qoderRoot?.encodeProjectDir?.('/Users/a/b/proj')).toBe(
      '-Users-a-b-proj',
    );
  });
});

describe('encodeIflow', () => {
  it('mirrors iFlow CLI: strips leading/trailing dashes per segment', () => {
    // Real observed cases on dev machine:
    expect(encodeIflow('/Users/bing/-Code-/coding-memory')).toBe(
      '-Users-bing-Code-coding-memory',
    );
    expect(encodeIflow('/Users/bing/-Code-/engram')).toBe(
      '-Users-bing-Code-engram',
    );
    expect(encodeIflow('/Users/bing/-Code-/WebSite_GLM')).toBe(
      '-Users-bing-Code-WebSite_GLM',
    );
  });
});

describe('encodeGemini', () => {
  it('mirrors Gemini CLI project-root SHA-256 directory names', () => {
    expect(encodeGemini('/Users/bing/-Code-')).toBe(
      'f2b35ab42fab408079d691fc1e4b5fcc3721611ee3fc5a01e5d295dadfd4a01e',
    );
    expect(encodeGemini('/Users/bing/-NetWork-/Screen-disconnet-erro')).toBe(
      '6faefbf4c9b088f7c662b7ed311080cd0eae9a994198e6b81bca6f79108e2eea',
    );
    expect(encodeGemini('/Users/bing/-Code-/WebSite_Gemini')).toBe(
      '14c0b06be029ed0eec4a9c32d825e06252ec7b3893898df56a8891dba6fdebf2',
    );
    expect(encodeGemini('/Users/bing/-Code-/mac_Book_Pro_Debug')).toBe(
      'd4a081da72ab6feb63ddbbacad9c14d4bf185694ba07a984f3b03d24a2e9020b',
    );
    expect(encodeGemini('/a/_foo_')).toBe(
      '380ff7c65714acba22d3ab3c5550fb6a1e96c89b3692093b0852866016f46aef',
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

  it('yields session JSON files and Gemini project root markers', async () => {
    writeFileSync(join(tmp, 'session.jsonl'), 'x');
    writeFileSync(join(tmp, 'config.json'), 'x');
    writeFileSync(join(tmp, '.project_root'), 'x');
    writeFileSync(join(tmp, 'readme.md'), 'x');
    writeFileSync(join(tmp, 'binary.bin'), 'x');

    const seen: string[] = [];
    for await (const f of walkSessionFiles(tmp)) seen.push(f);
    expect(seen.sort()).toEqual(
      [
        join(tmp, '.project_root'),
        join(tmp, 'config.json'),
        join(tmp, 'session.jsonl'),
      ].sort(),
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
    writeFileSync(join(tmp, 'a.jsonl'), '{"cwd":"/Users/bing/foo"}');
    writeFileSync(join(tmp, 'b.jsonl'), '{"cwd":"/Users/bing/bar"}');
    writeFileSync(join(tmp, 'c.jsonl'), 'nothing interesting');

    const hits = await findReferencingFiles(tmp, '/Users/bing/foo');
    expect(hits).toEqual([join(tmp, 'a.jsonl')]);
  });

  it('findReferencingFiles includes Gemini .project_root markers', async () => {
    writeFileSync(join(tmp, '.project_root'), '/Users/bing/gemini-proj\n');
    writeFileSync(join(tmp, 'a.jsonl'), '{"cwd":"/Users/bing/other"}');

    const hits = await findReferencingFiles(tmp, '/Users/bing/gemini-proj');
    expect(hits).toEqual([join(tmp, '.project_root')]);
  });

  it('findReferencingFiles handles UTF-8 needles', async () => {
    writeFileSync(join(tmp, 'a.jsonl'), '{"cwd":"/项目/旧"}');
    writeFileSync(join(tmp, 'b.jsonl'), '{"cwd":"/other"}');

    const hits = await findReferencingFiles(tmp, '/项目/旧');
    expect(hits).toEqual([join(tmp, 'a.jsonl')]);
  });

  it('findReferencingFiles finds NFD path text when caller passes NFC needle', async () => {
    const nfc = '/Users/bing/café';
    const nfd = nfc.normalize('NFD');
    writeFileSync(join(tmp, 'a.jsonl'), JSON.stringify({ cwd: nfd }));
    writeFileSync(join(tmp, 'b.jsonl'), JSON.stringify({ cwd: '/other' }));

    const hits = await findReferencingFiles(tmp, nfc);
    expect(hits).toEqual([join(tmp, 'a.jsonl')]);
  });

  it('findReferencingFiles finds NFC path text when caller passes NFD needle', async () => {
    const nfc = '/Users/bing/café';
    const nfd = nfc.normalize('NFD');
    writeFileSync(join(tmp, 'a.jsonl'), JSON.stringify({ cwd: nfc }));
    writeFileSync(join(tmp, 'b.jsonl'), JSON.stringify({ cwd: '/other' }));

    const hits = await findReferencingFiles(tmp, nfd);
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

  it('walkSessionFiles does not apply the old 128 MiB cap by default', async () => {
    const big = join(tmp, 'big.jsonl');
    writeFileSync(big, '{"cwd":"/old"}\n');
    truncateSync(big, 128 * 1024 * 1024 + 4096);

    const issues: WalkIssue[] = [];
    const seen: string[] = [];
    for await (const f of walkSessionFiles(tmp, {
      onIssue: (i) => issues.push(i),
    })) {
      seen.push(f);
    }

    expect(seen).toEqual([big]);
    expect(issues).toEqual([]);
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
