import { execFileSync } from 'node:child_process';
import { mkdtempSync, readFileSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { resolve } from 'node:path';
import { describe, expect, it } from 'vitest';

const repoRoot = resolve(import.meta.dirname, '../..');
const script = resolve(repoRoot, 'scripts/check-invariants-ledger.sh');
const checkedPathPrefixes = [
  'macos/',
  'src/',
  'scripts/',
  'tests/',
  'test-fixtures/',
  'docs/',
  '.github/',
];

function runScript(args: string[] = [], cwd = repoRoot): string {
  return execFileSync('bash', [script, ...args], {
    cwd,
    encoding: 'utf8',
    stdio: ['ignore', 'pipe', 'pipe'],
  });
}

describe('invariants ledger gate script', () => {
  it('passes for the repo invariants ledger', () => {
    expect(runScript()).toContain('invariants ledger ok');
  });

  it('keeps enforced and verified anchors inside the checked path set', () => {
    const ledger = readFileSync(
      resolve(repoRoot, 'docs/invariants.md'),
      'utf8',
    );
    const anchorLines = ledger
      .split('\n')
      .filter((line) => /^- \*\*(Enforced by|Verified by)\*\*/.test(line));
    const uncheckedAnchors = anchorLines
      .flatMap((line) =>
        Array.from(line.matchAll(/`([^`]+)`/g), (match) => match[1].trim()),
      )
      .filter(
        (token) =>
          !checkedPathPrefixes.some((prefix) => token.startsWith(prefix)),
      );

    expect(uncheckedAnchors).toEqual([]);
  });

  it('rejects backticked repo-relative paths that do not exist', () => {
    const tempDir = mkdtempSync(resolve(tmpdir(), 'engram-invariants-ledger-'));
    const ledger = resolve(tempDir, 'invariants.md');
    writeFileSync(
      ledger,
      [
        '# Invariants',
        '',
        '- **Statement** - Missing-path sentinel.',
        '- **Enforced by** - `docs/does-not-exist.md`.',
        '- **Verified by** - `tests/scripts/invariants-ledger.test.ts`.',
      ].join('\n'),
    );

    expect(() => runScript([ledger])).toThrow(/docs\/does-not-exist\.md/);
  });

  it('strips line suffixes and reports every missing path', () => {
    const tempDir = mkdtempSync(resolve(tmpdir(), 'engram-invariants-ledger-'));
    const ledger = resolve(tempDir, 'invariants.md');
    writeFileSync(
      ledger,
      [
        '# Invariants',
        '',
        '- **Enforced by** - `docs/invariants.md:1`.',
        '- **Verified by** - `docs/missing-one.md`, `tests/missing-two.ts`.',
      ].join('\n'),
    );

    expect(() => runScript([ledger])).toThrow(
      /docs\/missing-one\.md[\s\S]*tests\/missing-two\.ts/,
    );
  });
});
