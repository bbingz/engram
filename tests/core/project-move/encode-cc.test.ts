import { describe, expect, it } from 'vitest';
import { encodeCC } from '../../../src/core/project-move/encode-cc.js';

describe('encodeCC', () => {
  it('replaces every slash with dash', () => {
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

  it('replaces underscores with dash (every non-alnum char -> dash)', () => {
    expect(encodeCC('/Users/john_doe/my-proj')).toBe('-Users-john-doe-my-proj');
  });

  it('replaces dots with dash', () => {
    expect(encodeCC('/Users/bing/.config/superpowers')).toBe(
      '-Users-bing--config-superpowers',
    );
    expect(encodeCC('/Users/bing/node-v18.2.0')).toBe(
      '-Users-bing-node-v18-2-0',
    );
  });

  it('replaces spaces with dash', () => {
    expect(encodeCC('/Users/bing/my proj')).toBe('-Users-bing-my-proj');
  });

  it('handles trailing slash (naive replace — caller normalizes)', () => {
    expect(encodeCC('/a/b/')).toBe('-a-b-');
  });

  it('empty string passes through', () => {
    expect(encodeCC('')).toBe('');
  });

  it('keeps exactly 200 encoded UTF-16 code units unchanged', () => {
    expect(encodeCC(`/Users/bing/${'a'.repeat(188)}`)).toBe(
      `-Users-bing-${'a'.repeat(188)}`,
    );
  });

  it('truncates encoded names longer than 200 UTF-16 code units with hash suffix', () => {
    expect(encodeCC(`/Users/bing/${'a'.repeat(189)}`)).toBe(
      `-Users-bing-${'a'.repeat(188)}-fqx13c`,
    );
    expect(encodeCC(`/Users/bing/-Code-/${'Project_'.repeat(35)}`)).toBe(
      '-Users-bing--Code--Project-Project-Project-Project-Project-Project-Project-Project-Project-Project-Project-Project-Project-Project-Project-Project-Project-Project-Project-Project-Project-Project-Proje-6bilpn',
    );
  });

  it('uses JavaScript UTF-16 code-unit semantics for long emoji paths', () => {
    expect(encodeCC(`/Users/bing/-Code-/${'emoji🙂'.repeat(35)}`)).toBe(
      '-Users-bing--Code--emoji--emoji--emoji--emoji--emoji--emoji--emoji--emoji--emoji--emoji--emoji--emoji--emoji--emoji--emoji--emoji--emoji--emoji--emoji--emoji--emoji--emoji--emoji--emoji--emoji--emoji--uooe3s',
    );
  });

  // Real-corpus regression: expected dir names are hardcoded literals captured
  // from real ~/.claude/projects dirs, locking the rule against regression.
  it('matches real on-disk dirs for divergent paths', () => {
    expect(encodeCC('/Users/bing/-Code-/CCTV_Admin')).toBe(
      '-Users-bing--Code--CCTV-Admin',
    );
    expect(
      encodeCC('/Users/bing/Library/Application Support/CodexBar/ClaudeProbe'),
    ).toBe('-Users-bing-Library-Application-Support-CodexBar-ClaudeProbe');
  });
});
