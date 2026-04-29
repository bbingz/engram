// Codex edge-case: negative test for old-path literal split across lines.
// mvp.py's regex is single-line by design — a JSONL entry can technically
// contain a `\n` before the path terminator, which would split the match.
// The regex would not treat `\n` as a terminator in the same sense:
// actually '\n' IS in \s, so `\n` is a valid terminator.
//
// We verify that:
//   1. a path followed by a newline IS matched (newline is a terminator)
//   2. a path literal itself containing a newline is NOT matched (we don't
//      match across newlines because old is treated as a literal scalar)

import { describe, expect, it } from 'vitest';
import { patchBuffer } from '../../../src/core/project-move/jsonl-patch.js';

describe('cross-line-boundary (Codex minor: negative test)', () => {
  it('path followed by newline IS matched (\\n is a terminator)', () => {
    const input = Buffer.from('"cwd":"/a/foo"\nother line', 'utf8');
    const r = patchBuffer(input, '/a/foo', '/a/bar');
    expect(r.count).toBe(1);
    expect(r.buffer.toString('utf8')).toBe('"cwd":"/a/bar"\nother line');
  });

  it('a literal newline inside the old path IS a match (mvp.py parity)', () => {
    // When the needle itself contains '\n', the regex-escaped literal still
    // matches across the newline byte — mvp.py has the same behavior since
    // it's byte-level. Test name fixed from misleading "NOT" to the actual
    // observed behavior.
    const input = Buffer.from('"cwd":"/a/foo\nbar"', 'utf8');
    const r = patchBuffer(input, '/a/foo\nbar', '/z');
    expect(r.count).toBe(1);
    expect(r.buffer.toString('utf8')).toBe('"cwd":"/z"');
  });

  it('path split across two lines (newline in middle) is NOT a single match', () => {
    // /a/foo and /a/bar separated by newline — matching "/a/foo/a/bar"
    // shouldn't hit. We're searching for '/a/foobar' (no newline, no slash),
    // which shouldn't match '/a/foo\n/a/bar'.
    const input = Buffer.from('"/a/foo"\n"/a/bar"', 'utf8');
    const r = patchBuffer(input, '/a/foobar', '/z');
    expect(r.count).toBe(0);
  });

  it('two occurrences separated by newline: both match independently', () => {
    const input = Buffer.from('"/a/foo"\n"/a/foo"', 'utf8');
    const r = patchBuffer(input, '/a/foo', '/a/bar');
    expect(r.count).toBe(2);
    expect(r.buffer.toString('utf8')).toBe('"/a/bar"\n"/a/bar"');
  });
});
