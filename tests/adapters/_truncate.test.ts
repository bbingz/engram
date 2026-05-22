// tests/adapters/_truncate.test.ts

import { describe, expect, it } from 'vitest';
import { truncateJSON, truncateString } from '../../src/adapters/_truncate.js';

// A string is well-formed UTF-16 iff it has no lone surrogate halves.
// JSON.stringify throws on lone surrogates in some engines but, more
// importantly, downstream consumers reject them — so the result must never
// contain one regardless of where the cut lands.
function hasLoneSurrogate(s: string): boolean {
  for (let i = 0; i < s.length; i++) {
    const code = s.charCodeAt(i);
    if (code >= 0xd800 && code <= 0xdbff) {
      const next = i + 1 < s.length ? s.charCodeAt(i + 1) : 0;
      if (next < 0xdc00 || next > 0xdfff) return true; // unpaired high
      i++; // valid pair, skip the low half
    } else if (code >= 0xdc00 && code <= 0xdfff) {
      return true; // low half not preceded by a high half
    }
  }
  return false;
}

describe('truncateString surrogate safety (R5-36)', () => {
  it('drops a trailing high-surrogate when its low half is cut off', () => {
    // '😀' is a surrogate pair (0xD83D 0xDE00). Cut between the halves.
    const value = `ab😀`;
    const out = truncateString(value, 3); // keeps 'ab' + lone high half → drop
    expect(out).toBe('ab');
    expect(hasLoneSurrogate(out)).toBe(false);
  });

  it('drops a trailing lone low-surrogate (malformed input)', () => {
    // Construct a string whose char at the cut boundary is a lone low half.
    const loneLow = String.fromCharCode(0xdc00);
    const value = `xy${loneLow}z`;
    const out = truncateString(value, 3); // 'xy' + lone low half → drop it
    expect(out).toBe('xy');
    expect(hasLoneSurrogate(out)).toBe(false);
  });

  it('keeps a complete surrogate pair that fits entirely within the cut', () => {
    const value = `a😀bc`;
    const out = truncateString(value, 3); // 'a' + full pair (length 3)
    expect(out).toBe('a😀');
    expect(hasLoneSurrogate(out)).toBe(false);
  });

  it('returns the string unchanged when shorter than max', () => {
    expect(truncateString('hi', 100)).toBe('hi');
  });
});

describe('truncateJSON', () => {
  it('returns undefined for null/undefined', () => {
    expect(truncateJSON(null, 100)).toBeUndefined();
    expect(truncateJSON(undefined, 100)).toBeUndefined();
  });

  it('never emits a lone surrogate after truncation', () => {
    const out = truncateJSON({ k: '😀😀😀😀' }, 10);
    expect(out).toBeDefined();
    expect(hasLoneSurrogate(out as string)).toBe(false);
  });
});
