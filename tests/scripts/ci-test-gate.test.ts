import { spawnSync } from 'node:child_process';
import { resolve } from 'node:path';
import { describe, expect, it } from 'vitest';

const repoRoot = resolve(import.meta.dirname, '../..');
const gate = resolve(repoRoot, 'scripts/ci/verify-test-gate.sh');

function verify(args: string[]) {
  return spawnSync('bash', [gate, ...args], {
    cwd: repoRoot,
    encoding: 'utf8',
  });
}

describe('Tests aggregate gate', () => {
  it.each([
    [
      'heavy pull request',
      [
        'success',
        'true',
        'success',
        'success',
        'success',
        'success',
        'success',
        'skipped',
        'pull_request',
      ],
    ],
    [
      'heavy main push',
      [
        'success',
        'true',
        'success',
        'success',
        'success',
        'success',
        'skipped',
        'success',
        'push',
      ],
    ],
    [
      'durable-docs-only change',
      [
        'success',
        'false',
        'skipped',
        'skipped',
        'skipped',
        'skipped',
        'skipped',
        'skipped',
        'pull_request',
      ],
    ],
  ])('accepts %s', (_name, args) => {
    expect(verify(args).status).toBe(0);
  });

  it.each([
    [
      'blank classifier output',
      [
        'success',
        '',
        'skipped',
        'skipped',
        'skipped',
        'skipped',
        'skipped',
        'skipped',
        'pull_request',
      ],
    ],
    [
      'invalid classifier output',
      [
        'success',
        'yes',
        'skipped',
        'skipped',
        'skipped',
        'skipped',
        'skipped',
        'skipped',
        'pull_request',
      ],
    ],
    [
      'required lane failure',
      [
        'success',
        'true',
        'success',
        'success',
        'failure',
        'success',
        'success',
        'skipped',
        'pull_request',
      ],
    ],
    [
      'unexpected docs-only execution',
      [
        'success',
        'false',
        'success',
        'skipped',
        'skipped',
        'skipped',
        'skipped',
        'skipped',
        'pull_request',
      ],
    ],
  ])('rejects %s', (_name, args) => {
    expect(verify(args).status).not.toBe(0);
  });
});
