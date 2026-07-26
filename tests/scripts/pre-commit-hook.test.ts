import { spawnSync } from 'node:child_process';
import { chmodSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { afterEach, describe, expect, it } from 'vitest';

const repoRoot = resolve(import.meta.dirname, '../..');
const hook = resolve(repoRoot, '.husky/pre-commit');
let tempDir: string | undefined;

afterEach(() => {
  if (tempDir) {
    rmSync(tempDir, { recursive: true, force: true });
    tempDir = undefined;
  }
});

describe('pre-commit hook', () => {
  it('propagates lint-staged failures', () => {
    tempDir = mkdtempSync(join(tmpdir(), 'engram-pre-commit-'));
    const fakeNpx = join(tempDir, 'npx');
    const fakeGit = join(tempDir, 'git');
    writeFileSync(
      fakeNpx,
      '#!/bin/sh\nprintf "fake lint-staged failure\\n" >&2\nexit 42\n',
    );
    writeFileSync(fakeGit, '#!/bin/sh\nexit 1\n');
    chmodSync(fakeNpx, 0o700);
    chmodSync(fakeGit, 0o700);

    const result = spawnSync('/bin/sh', [hook], {
      cwd: repoRoot,
      encoding: 'utf8',
      env: {
        ...process.env,
        PATH: `${tempDir}:${process.env.PATH ?? ''}`,
      },
    });

    expect(result.status).toBe(42);
    expect(result.stderr).toContain('fake lint-staged failure');
  });
});
