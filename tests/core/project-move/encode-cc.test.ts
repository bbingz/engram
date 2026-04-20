import { describe, expect, it } from 'vitest';
import { encodeCC } from '../../../src/core/project-move/encode-cc.js';

describe('encodeCC', () => {
  it('replaces every slash with dash (mvp.py parity)', () => {
    expect(encodeCC('/Users/bing/-Code-/engram')).toBe(
      '-Users-bing--Code--engram',
    );
  });

  it('handles root path', () => {
    expect(encodeCC('/')).toBe('-');
  });

  it('handles consecutive slashes (ambiguous but lossy by design)', () => {
    expect(encodeCC('/a//b')).toBe('-a--b');
  });

  it('preserves dashes and underscores in the source', () => {
    expect(encodeCC('/Users/john_doe/my-proj')).toBe('-Users-john_doe-my-proj');
  });

  it('handles spaces', () => {
    expect(encodeCC('/Users/bing/my proj')).toBe('-Users-bing-my proj');
  });

  it('handles trailing slash', () => {
    // mvp.py does a naive replace — trailing slash becomes trailing dash.
    // Caller is responsible for normalizing absolute paths beforehand.
    expect(encodeCC('/a/b/')).toBe('-a-b-');
  });

  it('empty string passes through', () => {
    expect(encodeCC('')).toBe('');
  });
});
