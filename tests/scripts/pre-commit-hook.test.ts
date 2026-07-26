import { spawnSync } from 'node:child_process';
import { chmodSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';

const repoRoot = resolve(import.meta.dirname, '../..');
const hook = resolve(repoRoot, '.husky/pre-commit');
let tempDir: string;

beforeEach(() => {
  tempDir = mkdtempSync(join(tmpdir(), 'engram-pre-commit-'));
});

afterEach(() => {
  rmSync(tempDir, { recursive: true, force: true });
});

function stubCommand(name: string, script: string) {
  const path = join(tempDir, name);
  writeFileSync(path, `#!/bin/sh\n${script}\n`);
  chmodSync(path, 0o700);
}

function runHook() {
  return spawnSync(hook, [], {
    cwd: repoRoot,
    encoding: 'utf8',
    env: {
      ...process.env,
      PATH: `${tempDir}:${process.env.PATH ?? ''}`,
    },
  });
}

describe('pre-commit hook', () => {
  // PR #234: a lint-staged failure must abort the hook with the same status.
  it('propagates lint-staged failures (repro)', () => {
    stubCommand('npx', 'printf "fake lint-staged failure\\n" >&2\nexit 42');
    stubCommand('git', 'exit 1');

    const result = runHook();

    expect(result.error).toBeUndefined();
    expect(result.signal).toBeNull();
    expect(result.status).toBe(42);
    expect(result.stderr).toContain('fake lint-staged failure');
  });

  it('returns zero when lint-staged succeeds', () => {
    stubCommand('npx', 'exit 0');
    stubCommand('git', 'exit 1');

    const result = runHook();

    expect(result.error).toBeUndefined();
    expect(result.signal).toBeNull();
    expect(result.status).toBe(0);
  });
});
