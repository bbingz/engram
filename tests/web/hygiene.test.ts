// tests/web/hygiene.test.ts

import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { Database } from '../../src/core/db.js';
import type { ShellExecutor } from '../../src/core/health-rules.js';
import { runAllHealthChecks } from '../../src/core/health-rules.js';

describe('runAllHealthChecks', () => {
  let db: Database;
  let tmpDir: string;

  // A no-op shell executor so we don't run real git/ps commands in tests
  const noopShell: ShellExecutor = async () => ({ stdout: '', stderr: '' });

  beforeEach(() => {
    tmpDir = mkdtempSync(join(tmpdir(), 'hygiene-test-'));
    db = new Database(join(tmpDir, 'test.sqlite'));
  });

  afterEach(() => {
    db.close();
    rmSync(tmpDir, { recursive: true });
  });

  it('returns correct schema: issues array, score 0-100, checkedAt ISO string', async () => {
    const result = await runAllHealthChecks(db, {
      force: true,
      shell: noopShell,
    });

    expect(result).toHaveProperty('issues');
    expect(result).toHaveProperty('score');
    expect(result).toHaveProperty('checkedAt');

    expect(Array.isArray(result.issues)).toBe(true);
    expect(typeof result.score).toBe('number');
    expect(result.score).toBeGreaterThanOrEqual(0);
    expect(result.score).toBeLessThanOrEqual(100);
    expect(typeof result.checkedAt).toBe('string');
    // checkedAt should be a valid ISO 8601 string
    expect(new Date(result.checkedAt).toISOString()).toBe(result.checkedAt);
  });

  it('returns empty issues and score 100 when shell finds nothing', async () => {
    const result = await runAllHealthChecks(db, {
      force: true,
      shell: noopShell,
    });

    expect(result.issues).toHaveLength(0);
    expect(result.score).toBe(100);
  });

  it('force: true bypasses the cache and returns fresh result', async () => {
    // First call populates cache
    const first = await runAllHealthChecks(db, {
      force: true,
      shell: noopShell,
    });
    const firstCheckedAt = first.checkedAt;

    // Wait 1ms to ensure different timestamp
    await new Promise((r) => setTimeout(r, 1));

    // Second forced call should return new checkedAt
    const second = await runAllHealthChecks(db, {
      force: true,
      shell: noopShell,
    });
    expect(second.checkedAt).not.toBe(firstCheckedAt);
  });

  it('cached result is returned within TTL when force is false', async () => {
    // Populate cache
    const first = await runAllHealthChecks(db, {
      force: true,
      shell: noopShell,
    });

    // Immediately call without force — should hit cache (same checkedAt)
    const cached = await runAllHealthChecks(db, {
      force: false,
      shell: noopShell,
    });
    expect(cached.checkedAt).toBe(first.checkedAt);
  });

  it('issues have correct shape when shell reports a problem', async () => {
    // Shell that reports stale branches (>3)
    const shellWithStaleBranches: ShellExecutor = async (cmd, args) => {
      if (cmd === 'git' && args.includes('symbolic-ref')) {
        return { stdout: 'origin/main\n', stderr: '' };
      }
      if (cmd === 'git' && args.includes('--merged')) {
        return {
          stdout: '  branch-a\n  branch-b\n  branch-c\n  branch-d\n',
          stderr: '',
        };
      }
      return { stdout: '', stderr: '' };
    };

    const result = await runAllHealthChecks(db, {
      force: true,
      scope: 'project',
      cwd: tmpDir,
      shell: shellWithStaleBranches,
    });

    expect(result.issues.length).toBeGreaterThan(0);
    const staleBranchIssue = result.issues.find(
      (i) => i.kind === 'stale_branches',
    );
    expect(staleBranchIssue).toBeDefined();
    expect(staleBranchIssue?.severity).toMatch(/^(error|warning|info)$/);
    expect(typeof staleBranchIssue?.message).toBe('string');

    // Score should be < 100 since there are issues
    expect(result.score).toBeLessThan(100);
  });
});
