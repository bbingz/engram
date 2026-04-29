// tests/tools/list_sessions.test.ts

import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { Database } from '../../src/core/db.js';
import {
  handleListSessions,
  listSessionsTool,
} from '../../src/tools/list_sessions.js';

describe('list_sessions tool', () => {
  let db: Database;
  let tmpDir: string;

  beforeEach(() => {
    tmpDir = mkdtempSync(join(tmpdir(), 'tools-test-'));
    db = new Database(join(tmpDir, 'test.sqlite'));
    db.upsertSession({
      id: 's1',
      source: 'codex',
      startTime: '2026-01-01T10:00:00Z',
      cwd: '/pa',
      project: 'project-a',
      messageCount: 10,
      userMessageCount: 5,
      assistantMessageCount: 0,
      toolMessageCount: 0,
      systemMessageCount: 0,
      filePath: '/f1',
      sizeBytes: 100,
    });
    db.upsertSession({
      id: 's2',
      source: 'claude-code',
      startTime: '2026-01-02T10:00:00Z',
      cwd: '/pb',
      project: 'project-b',
      messageCount: 8,
      userMessageCount: 4,
      assistantMessageCount: 0,
      toolMessageCount: 0,
      systemMessageCount: 0,
      filePath: '/f2',
      sizeBytes: 200,
    });
    db.upsertSession({
      id: 's3',
      source: 'codex',
      startTime: '2025-12-01T10:00:00Z',
      cwd: '/pa',
      project: 'project-a',
      messageCount: 5,
      userMessageCount: 2,
      assistantMessageCount: 0,
      toolMessageCount: 0,
      systemMessageCount: 0,
      filePath: '/f3',
      sizeBytes: 50,
    });
  });

  afterEach(() => {
    db.close();
    rmSync(tmpDir, { recursive: true });
  });

  it('returns all sessions without filters', async () => {
    const result = await handleListSessions(db, {});
    expect(result.sessions).toHaveLength(3);
  });

  it('filters by source', async () => {
    const result = await handleListSessions(db, { source: 'codex' });
    expect(result.sessions).toHaveLength(2);
    expect(result.sessions.every((s) => s.source === 'codex')).toBe(true);
  });

  it('filters by since date', async () => {
    const result = await handleListSessions(db, {
      since: '2026-01-01T00:00:00Z',
    });
    expect(result.sessions).toHaveLength(2);
  });

  it('tool schema has correct name', () => {
    expect(listSessionsTool.name).toBe('list_sessions');
    expect(listSessionsTool.inputSchema.type).toBe('object');
  });
});
