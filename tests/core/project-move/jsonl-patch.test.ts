// Independent invariant tests for jsonl-patch — do not rely on Python mvp
// as an oracle. These enumerate the semantic properties mvp.py's regex was
// designed to have. Golden diff-tests (separate file) cross-check byte parity.

import {
  closeSync,
  mkdtempSync,
  openSync,
  readFileSync,
  readSync,
  rmSync,
  truncateSync,
  writeFileSync,
} from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import {
  autoFixDotQuote,
  ConcurrentModificationError,
  patchBuffer,
  patchFile,
} from '../../../src/core/project-move/jsonl-patch.js';

// Deterministic CAS support for the "mtime changes during patch" test below.
// When armed for a path, the SECOND+ fs/promises.stat call for it reports a
// +60s mtime — simulating a concurrent writer between patchFile's initial
// read-stat and its pre-rename re-stat. Disarmed (armedPath === null) it is a
// pure pass-through, so every other test exercises the real stat. The previous
// setup (queueMicrotask + utimesSync) raced patchFile's first stat and was
// flaky on slow CI runners, where the bump could land before that first stat.
const statCas = vi.hoisted(() => ({
  armedPath: null as string | null,
  calls: 0,
}));

vi.mock('node:fs/promises', async (importOriginal) => {
  const actual = await importOriginal<typeof import('node:fs/promises')>();
  return {
    ...actual,
    stat: (async (path: Parameters<typeof actual.stat>[0]) => {
      const st = await actual.stat(path);
      if (statCas.armedPath !== null && String(path) === statCas.armedPath) {
        statCas.calls += 1;
        if (statCas.calls >= 2) {
          (st as unknown as { mtimeMs: number }).mtimeMs += 60_000;
        }
      }
      return st;
    }) as typeof actual.stat,
  };
});

const patch = (data: string, oldPath: string, newPath: string) => {
  const buf = Buffer.from(data, 'utf8');
  const res = patchBuffer(buf, oldPath, newPath);
  return { text: res.buffer.toString('utf8'), count: res.count };
};

describe('patchBuffer — mvp.py 1:1 parity', () => {
  describe('idempotent / symmetric', () => {
    it('running the same patch twice is a no-op on second run', () => {
      const once = patch('"/a/foo/x"', '/a/foo', '/a/bar');
      expect(once.text).toBe('"/a/bar/x"');
      expect(once.count).toBe(1);
      const twice = patch(once.text, '/a/foo', '/a/bar');
      expect(twice.text).toBe(once.text);
      expect(twice.count).toBe(0);
    });

    it('symmetric: patch(A→B) then patch(B→A) restores bytes', () => {
      const original = '"/a/foo/x"';
      const forward = patch(original, '/a/foo', '/a/bar').text;
      const back = patch(forward, '/a/bar', '/a/foo').text;
      expect(back).toBe(original);
    });
  });

  describe('prefix boundary', () => {
    it('/foo/bar does NOT match /foo/bar-baz inside the same string', () => {
      // mvp.py: the terminator lookahead excludes '-' so `-baz` is fine
      const input = '"/foo/bar-baz"';
      expect(patch(input, '/foo/bar', '/foo/new').count).toBe(0);
      expect(patch(input, '/foo/bar', '/foo/new').text).toBe('"/foo/bar-baz"');
    });

    it('/foo/bar does NOT match /foo/barbar', () => {
      const input = '"/foo/barbar/x"';
      expect(patch(input, '/foo/bar', '/foo/new').count).toBe(0);
    });

    it('/foo/bar DOES match /foo/bar followed by /', () => {
      expect(patch('"/foo/bar/x"', '/foo/bar', '/foo/new').text).toBe(
        '"/foo/new/x"',
      );
    });
  });

  describe('terminator chars (mvp.py: ["\'/\\<>])}` whitespace EOF)', () => {
    // mvp.py's regex: (?=["'/\\<>\])}`\s]|$)
    const OLD = '/a/b';
    const NEW = '/a/c';
    const cases: Array<[string, string, string]> = [
      // [description, terminator char inserted after OLD, should match]
      ['double quote', '"', '"/a/b"rest'],
      ['single quote', "'", "'/a/b'rest"],
      ['slash', '/', '"/a/b/x"'],
      ['backslash', '\\', '"/a/b\\x"'],
      ['less-than', '<', '"/a/b<x"'],
      ['greater-than', '>', '"/a/b>x"'],
      ['close-bracket', ']', '"/a/b]rest'],
      ['close-paren', ')', '"/a/b)rest'],
      ['close-brace', '}', '"/a/b}rest'],
      ['backtick', '`', '"/a/b`rest'],
      ['space', ' ', '/a/b rest'],
      ['tab', '\t', '/a/b\trest'],
      ['newline', '\n', '/a/b\nrest'],
    ];
    for (const [desc, _terminator, input] of cases) {
      it(`matches when followed by ${desc}`, () => {
        const r = patch(input, OLD, NEW);
        expect(r.count).toBe(1);
        expect(r.text).toBe(input.replace(OLD, NEW));
      });
    }

    it('matches when at end-of-input (no terminator)', () => {
      const r = patch('/a/b', OLD, NEW);
      expect(r.count).toBe(1);
      expect(r.text).toBe('/a/c');
    });
  });

  describe('exclusion chars (. , ; - _ NOT terminators)', () => {
    const OLD = '/a/b';
    const NEW = '/a/c';
    const exclusions: Array<[string, string]> = [
      ['.', '/a/b.bak'],
      [',', '/a/b,x'],
      [';', '/a/b;x'],
      ['-', '/a/b-baz'],
      ['_', '/a/b_x'],
      ['alnum', '/a/b9x'],
      ['alpha', '/a/bX'],
    ];
    for (const [desc, input] of exclusions) {
      it(`does NOT match when followed by ${desc}`, () => {
        expect(patch(input, OLD, NEW).count).toBe(0);
      });
    }
  });

  describe('UTF-8 safety', () => {
    it('preserves Chinese characters in surrounding context', () => {
      const input = '"cwd": "/Users/bing/项目/旧", "other": "保留"';
      const r = patch(input, '/Users/bing/项目/旧', '/Users/bing/项目/新');
      expect(r.count).toBe(1);
      expect(r.text).toBe('"cwd": "/Users/bing/项目/新", "other": "保留"');
    });

    it('old path itself contains UTF-8 characters', () => {
      const r = patch('"/项目/子目录"', '/项目', '/proj');
      expect(r.count).toBe(1);
      expect(r.text).toBe('"/proj/子目录"');
    });
  });

  describe('LIKE-wildcard path safety (_ and % literal)', () => {
    it('underscore in path is treated literally, not as wildcard', () => {
      const r = patch(
        '"/Users/john_doe/proj"',
        '/Users/john_doe',
        '/Users/john_doe-new',
      );
      expect(r.count).toBe(1);
      expect(r.text).toBe('"/Users/john_doe-new/proj"');
    });
  });

  describe('regex metacharacters in old path', () => {
    it('escapes . in old path (does NOT treat as any-char wildcard)', () => {
      // If '.' were unescaped regex, '/a.b' would match '/aXb' too.
      const input = '"/aXb/c"';
      expect(patch(input, '/a.b', '/z').count).toBe(0);
    });

    it('escapes $ and +', () => {
      const r = patch('"/weird+$path/x"', '/weird+$path', '/normal');
      expect(r.count).toBe(1);
      expect(r.text).toBe('"/normal/x"');
    });
  });

  describe('multiple occurrences', () => {
    it('replaces all occurrences', () => {
      const input = '"/a/b/1" "/a/b/2" "/a/b/3"';
      const r = patch(input, '/a/b', '/z');
      expect(r.count).toBe(3);
      expect(r.text).toBe('"/z/1" "/z/2" "/z/3"');
    });
  });

  describe('empty / no-op', () => {
    it('no occurrences → count 0, buffer unchanged', () => {
      const input = 'no match here';
      const r = patchBuffer(Buffer.from(input, 'utf8'), '/a/b', '/a/c');
      expect(r.count).toBe(0);
      expect(r.buffer.equals(Buffer.from(input, 'utf8'))).toBe(true);
    });
  });

  describe('invalid UTF-8 input (Codex + Gemini blocker #1)', () => {
    it('throws InvalidUtf8Error on lone continuation byte', () => {
      // 0xFF is never valid in UTF-8
      const invalid = Buffer.concat([
        Buffer.from('/a/foo ', 'utf8'),
        Buffer.from([0xff]),
        Buffer.from(' rest', 'utf8'),
      ]);
      expect(() => patchBuffer(invalid, '/a/foo', '/a/bar')).toThrow(/utf-?8/i);
    });

    it('throws on truncated multi-byte sequence (e.g. half of emoji)', () => {
      // Truncated UTF-8 lead byte: 0xF0 0x9F 0x98 (missing 4th byte)
      const truncated = Buffer.concat([
        Buffer.from('"/a/foo/', 'utf8'),
        Buffer.from([0xf0, 0x9f, 0x98]),
      ]);
      expect(() => patchBuffer(truncated, '/a/foo', '/a/bar')).toThrow(
        /utf-?8/i,
      );
    });

    it('valid UTF-8 with 4-byte emoji passes through unchanged bytes', () => {
      // Full 4-byte emoji is valid UTF-8
      const input = Buffer.from('"/a/foo/sparkle-✨"', 'utf8');
      const r = patchBuffer(input, '/a/foo', '/a/bar');
      expect(r.count).toBe(1);
      expect(r.buffer.toString('utf8')).toBe('"/a/bar/sparkle-✨"');
    });
  });
});

describe('autoFixDotQuote (mvp.py:auto_fix_dot_quote)', () => {
  it('replaces <old>." → <new>."', () => {
    const buf = Buffer.from('Migrated to /a/foo."', 'utf8');
    const r = autoFixDotQuote(buf, '/a/foo', '/a/bar');
    expect(r.buffer.toString('utf8')).toBe('Migrated to /a/bar."');
    expect(r.count).toBe(1);
  });

  it('counts multiple sentence-end matches', () => {
    const buf = Buffer.from('/a/foo." then /a/foo." again', 'utf8');
    const r = autoFixDotQuote(buf, '/a/foo', '/a/bar');
    expect(r.count).toBe(2);
    expect(r.buffer.toString('utf8')).toBe('/a/bar." then /a/bar." again');
  });

  it('does NOT match bare /a/foo (without .")', () => {
    const buf = Buffer.from('/a/foo and /a/foo/x', 'utf8');
    const r = autoFixDotQuote(buf, '/a/foo', '/a/bar');
    expect(r.count).toBe(0);
  });

  it('does NOT match /a/foo."rest — the " must terminate the quote', () => {
    // mvp.py's auto_fix is literal bytes replace of `<old>."` — doesn't care
    // what comes after. Document this behavior: /a/foo."bar → /a/bar."bar.
    const buf = Buffer.from('/a/foo."bar', 'utf8');
    const r = autoFixDotQuote(buf, '/a/foo', '/a/bar');
    expect(r.count).toBe(1);
    expect(r.buffer.toString('utf8')).toBe('/a/bar."bar');
  });
});

describe('patchFile — concurrent-write CAS (Gemini blocker #2)', () => {
  let tmp: string;
  beforeEach(() => {
    tmp = mkdtempSync(join(tmpdir(), 'engram-patchfile-cas-'));
  });
  afterEach(() => {
    rmSync(tmp, { recursive: true, force: true });
  });

  it('happy path: writes new bytes, returns count', async () => {
    const p = join(tmp, 'a.jsonl');
    writeFileSync(p, '"cwd":"/old"');
    const count = await patchFile(p, '/old', '/new');
    expect(count).toBe(1);
    expect(readFileSync(p, 'utf8')).toBe('"cwd":"/new"');
  });

  it('throws ConcurrentModificationError when mtime changes during patch', async () => {
    const p = join(tmp, 'a.jsonl');
    writeFileSync(p, '"cwd":"/old"');
    // Deterministically simulate a concurrent writer: patchFile's first stat
    // captures the real mtime (its `before` snapshot), then the pre-rename
    // re-stat reports a bumped mtime so the CAS check fires.
    statCas.armedPath = p;
    statCas.calls = 0;
    try {
      await expect(patchFile(p, '/old', '/new')).rejects.toThrow(
        ConcurrentModificationError,
      );
    } finally {
      statCas.armedPath = null;
    }
  });

  it('zero replacements: no write attempted, no CAS check needed', async () => {
    const p = join(tmp, 'a.jsonl');
    writeFileSync(p, 'no match here');
    const count = await patchFile(p, '/old', '/new');
    expect(count).toBe(0);
    expect(readFileSync(p, 'utf8')).toBe('no match here');
  });

  it('streams files larger than the old in-memory cap instead of refusing them', async () => {
    const p = join(tmp, 'large.jsonl');
    writeFileSync(p, '{"cwd":"/old"}\n');
    truncateSync(p, 128 * 1024 * 1024 + 4096);

    const count = await patchFile(p, '/old', '/new');

    expect(count).toBe(1);
    const fd = openSync(p, 'r');
    try {
      const head = Buffer.alloc(32);
      const bytes = readSync(fd, head, 0, head.length, 0);
      expect(head.subarray(0, bytes).toString('utf8')).toContain('/new');
    } finally {
      closeSync(fd);
    }
  });
});
