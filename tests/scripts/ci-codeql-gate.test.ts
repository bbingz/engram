import { spawnSync } from 'node:child_process';
import { resolve } from 'node:path';
import { describe, expect, it } from 'vitest';

const repoRoot = resolve(import.meta.dirname, '../..');
const gate = resolve(repoRoot, 'scripts/ci/verify-codeql-gate.sh');

function verify(args: string[]) {
  return spawnSync('bash', [gate, ...args], {
    cwd: repoRoot,
    encoding: 'utf8',
  });
}

describe('CodeQL aggregate gate', () => {
  it.each([
    [
      'all required jobs succeeded',
      ['success', 'true', 'success', 'true', 'success', 'true', 'success'],
    ],
    [
      'source-free change skipped every scan',
      ['success', 'false', 'skipped', 'false', 'skipped', 'false', 'skipped'],
    ],
    [
      'TypeScript-only change ran only TypeScript',
      ['success', 'true', 'success', 'false', 'skipped', 'false', 'skipped'],
    ],
  ])('accepts %s', (_name, args) => {
    expect(verify(args).status).toBe(0);
  });

  it.each([
    [
      'classifier failure',
      ['failure', 'true', 'success', 'false', 'skipped', 'false', 'skipped'],
    ],
    [
      'required scan failure',
      ['success', 'true', 'failure', 'false', 'skipped', 'false', 'skipped'],
    ],
    [
      'unexpected scan execution',
      ['success', 'false', 'success', 'false', 'skipped', 'false', 'skipped'],
    ],
  ])('rejects %s', (_name, args) => {
    expect(verify(args).status).not.toBe(0);
  });
});
