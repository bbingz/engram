// tests/tools/export.test.ts

import { existsSync, mkdtempSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { Database } from '../../src/core/db.js';
import { handleExport } from '../../src/tools/export.js';

// Mock homedir so exported files go to tmpDir
vi.mock('node:os', async (importOriginal) => {
  const actual = await importOriginal<typeof import('node:os')>();
  return {
    ...actual,
    homedir: () => process.env.TEST_HOME_DIR || actual.homedir(),
  };
});

const SESSION_ID = 'abc12345-export-test';

const mockAdapter = {
  detect: async () => true,
  listSessionFiles: async function* () {
    yield 'test.json';
  },
  parseSessionInfo: async () => ({}),
  streamMessages: async function* (_filePath: string) {
    yield { role: 'user', content: 'Hello', timestamp: '2025-01-01T00:00:00Z' };
    yield {
      role: 'assistant',
      content: 'Hi there',
      timestamp: '2025-01-01T00:01:00Z',
    };
  },
} as any;

describe('export', () => {
  let db: Database;
  let tmpDir: string;

  beforeEach(() => {
    tmpDir = mkdtempSync(join(tmpdir(), 'export-test-'));
    process.env.TEST_HOME_DIR = tmpDir;
    db = new Database(join(tmpDir, 'test.sqlite'));
    db.upsertSession({
      id: SESSION_ID,
      source: 'claude-code',
      startTime: '2025-01-01T00:00:00Z',
      endTime: '2025-01-01T01:00:00Z',
      cwd: '/tmp/project',
      project: 'test-project',
      model: 'claude-sonnet-4-20250514',
      messageCount: 2,
      userMessageCount: 1,
      assistantMessageCount: 1,
      toolMessageCount: 0,
      systemMessageCount: 0,
      summary: 'Test session',
      filePath: '/tmp/test.jsonl',
      sizeBytes: 100,
    });
  });

  afterEach(() => {
    db.close();
    rmSync(tmpDir, { recursive: true });
    delete process.env.TEST_HOME_DIR;
  });

  it('exports markdown format', async () => {
    const result = await handleExport(db, mockAdapter, {
      id: SESSION_ID,
      format: 'markdown',
    });
    expect(result.format).toBe('markdown');
    expect(result.messageCount).toBe(2);
    expect(result.outputPath).toMatch(/\.md$/);
    expect(existsSync(result.outputPath)).toBe(true);

    const content = readFileSync(result.outputPath, 'utf8');
    expect(content).toContain(`# Session: ${SESSION_ID}`);
  });

  it('exports json format', async () => {
    const result = await handleExport(db, mockAdapter, {
      id: SESSION_ID,
      format: 'json',
    });
    expect(result.format).toBe('json');
    expect(result.outputPath).toMatch(/\.json$/);
    expect(existsSync(result.outputPath)).toBe(true);

    const content = readFileSync(result.outputPath, 'utf8');
    const parsed = JSON.parse(content);
    expect(parsed.session.id).toBe(SESSION_ID);
    expect(parsed.messages).toHaveLength(2);
  });

  it('throws when session not found', async () => {
    await expect(
      handleExport(db, mockAdapter, { id: 'nonexistent' }),
    ).rejects.toThrow('Session not found');
  });
});
