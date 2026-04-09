import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { afterEach, describe, expect, it } from 'vitest';
import { Database } from '../../src/core/db.js';

describe('getSourceStats', () => {
  let db: Database;
  let tmpDir: string;
  afterEach(() => {
    db?.close();
    if (tmpDir) rmSync(tmpDir, { recursive: true });
  });

  it('returns per-source stats with daily counts', () => {
    tmpDir = mkdtempSync(join(tmpdir(), 'db-health-'));
    db = new Database(join(tmpDir, 'test.sqlite'));
    const now = new Date();
    const today = now.toISOString();
    const yesterday = new Date(now.getTime() - 86400000).toISOString();

    db.upsertSession({
      id: 's1',
      source: 'claude-code',
      filePath: '/tmp/s1',
      cwd: '/tmp',
      startTime: today,
      messageCount: 5,
      userMessageCount: 3,
      assistantMessageCount: 2,
      toolMessageCount: 0,
      systemMessageCount: 0,
      sizeBytes: 100,
    } as any);
    db.upsertSession({
      id: 's2',
      source: 'claude-code',
      filePath: '/tmp/s2',
      cwd: '/tmp',
      startTime: yesterday,
      messageCount: 3,
      userMessageCount: 2,
      assistantMessageCount: 1,
      toolMessageCount: 0,
      systemMessageCount: 0,
      sizeBytes: 80,
    } as any);
    db.upsertSession({
      id: 's3',
      source: 'codex',
      filePath: '/tmp/s3',
      cwd: '/tmp',
      startTime: today,
      messageCount: 2,
      userMessageCount: 1,
      assistantMessageCount: 1,
      toolMessageCount: 0,
      systemMessageCount: 0,
      sizeBytes: 50,
    } as any);

    const stats = db.getSourceStats();
    expect(stats).toHaveLength(2);
    const claude = stats.find((s) => s.source === 'claude-code')!;
    expect(claude.sessionCount).toBe(2);
    expect(claude.latestIndexed).toBeDefined();
    expect(claude.dailyCounts).toHaveLength(7);
    expect(stats.find((s) => s.source === 'codex')?.sessionCount).toBe(1);
  });

  it('returns empty array when no sessions', () => {
    tmpDir = mkdtempSync(join(tmpdir(), 'db-health-'));
    db = new Database(join(tmpDir, 'test.sqlite'));
    expect(db.getSourceStats()).toEqual([]);
  });
});
