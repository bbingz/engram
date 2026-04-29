// tests/core/project-move/macos-path-edge-cases.test.ts
//
// Round 4 (Codex #3 / code-reviewer C4): macOS-specific path hazards
// that were previously unhandled:
//   1. APFS/HFS+ default is case-insensitive — a rename from /X/Foo to
//      /X/foo used to trigger DirCollisionError because stat(dst)
//      returned the source's inode. Fix: realpath comparison.
//   2. HFS+ stores filenames in NFD; an AI CLI writing JSONL on such
//      a volume may embed the path in NFD form. A user typing the
//      rename target in NFC would miss those occurrences. Fix: retry
//      with NFD-form needle in patchBuffer.

import { describe, expect, it } from 'vitest';
import { patchBuffer } from '../../../src/core/project-move/jsonl-patch.js';

describe('patchBuffer NFC/NFD fallback', () => {
  it('finds NFD-form occurrences when caller passes NFC needle', () => {
    // "café" — NFC has 4 codepoints; NFD decomposes é to e + U+0301.
    const nfc = '/Users/example/café-proj';
    const nfd = nfc.normalize('NFD');
    expect(nfd).not.toBe(nfc);
    expect(nfd.length).toBeGreaterThan(nfc.length);

    const jsonl = Buffer.from(
      `{"cwd":"${nfd}","message":"hello"}\n` +
        `{"cwd":"${nfd}/subdir","message":"more"}\n`,
      'utf8',
    );

    const result = patchBuffer(jsonl, nfc, '/Users/example/cafe-proj');
    // Both NFD-encoded paths should have been rewritten.
    expect(result.count).toBe(2);
    const out = result.buffer.toString('utf8');
    expect(out).not.toContain(nfd);
    expect(out).toContain('/Users/example/cafe-proj');
  });

  it('leaves file untouched when NFC matches directly', () => {
    const jsonl = Buffer.from(
      '{"cwd":"/Users/example/café-proj","x":1}\n',
      'utf8',
    );
    const result = patchBuffer(
      jsonl,
      '/Users/example/café-proj',
      '/Users/example/cafe-proj',
    );
    expect(result.count).toBe(1);
    expect(result.buffer.toString('utf8')).toContain(
      '/Users/example/cafe-proj',
    );
  });

  it('ASCII-only needle does NOT do redundant NFD pass', () => {
    // Pure ASCII is already NFC === NFD, so the secondary regex must
    // not double-count.
    const jsonl = Buffer.from('{"cwd":"/tmp/foo"}\n', 'utf8');
    const result = patchBuffer(jsonl, '/tmp/foo', '/tmp/bar');
    expect(result.count).toBe(1);
  });
});
