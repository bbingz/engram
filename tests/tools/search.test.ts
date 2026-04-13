// tests/tools/search.test.ts

import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { Database } from '../../src/core/db.js';
import { MetricsCollector } from '../../src/core/metrics.js';
import { handleSearch } from '../../src/tools/search.js';

describe('search', () => {
  let db: Database;
  let tmpDir: string;

  beforeEach(() => {
    tmpDir = mkdtempSync(join(tmpdir(), 'search-test-'));
    db = new Database(join(tmpDir, 'test.sqlite'));
    db.upsertSession({
      id: 's1',
      source: 'codex',
      startTime: '2026-01-01T10:00:00Z',
      cwd: '/p',
      messageCount: 5,
      userMessageCount: 2,
      assistantMessageCount: 0,
      toolMessageCount: 0,
      systemMessageCount: 0,
      filePath: '/f1',
      sizeBytes: 100,
    });
    db.indexSessionContent('s1', [
      { role: 'user', content: '帮我修复 SSL certificate error in nginx' },
    ]);
    db.upsertSession({
      id: 's2',
      source: 'claude-code',
      startTime: '2026-01-02T10:00:00Z',
      cwd: '/p',
      messageCount: 3,
      userMessageCount: 1,
      assistantMessageCount: 0,
      toolMessageCount: 0,
      systemMessageCount: 0,
      filePath: '/f2',
      sizeBytes: 50,
    });
    db.indexSessionContent('s2', [
      { role: 'user', content: '添加用户注册功能' },
    ]);
  });

  afterEach(() => {
    db.close();
    rmSync(tmpDir, { recursive: true });
  });

  it('finds session by keyword', async () => {
    const result = await handleSearch(db, { query: 'SSL' });
    expect(result.results.length).toBeGreaterThan(0);
    expect(result.results[0].session?.id).toBe('s1');
  });

  it('returns empty array for no match', async () => {
    const result = await handleSearch(db, { query: 'kubernetes' });
    expect(result.results).toHaveLength(0);
  });
});

describe('search sub-query metrics', () => {
  let db: Database;
  let metricsDb: Database;
  let collector: MetricsCollector;
  let tmpDir: string;

  beforeEach(() => {
    tmpDir = mkdtempSync(join(tmpdir(), 'search-metrics-'));
    db = new Database(join(tmpDir, 'test.sqlite'));
    metricsDb = new Database(':memory:');
    collector = new MetricsCollector(metricsDb.raw, { flushIntervalMs: 0 });
    // Seed using the same pattern as existing search tests
    db.upsertSession({
      id: 's1',
      source: 'codex',
      startTime: '2026-01-01T10:00:00Z',
      cwd: '/p',
      messageCount: 5,
      userMessageCount: 2,
      assistantMessageCount: 0,
      toolMessageCount: 0,
      systemMessageCount: 0,
      filePath: '/f1',
      sizeBytes: 100,
    });
    db.indexSessionContent('s1', [
      { role: 'user', content: 'test search content for metrics' },
    ]);
  });
  afterEach(() => {
    db.close();
    metricsDb.close();
    rmSync(tmpDir, { recursive: true });
  });

  it('records search.fts_ms when FTS runs', async () => {
    await handleSearch(
      db,
      { query: 'test search content' },
      { metrics: collector },
    );
    collector.flush();
    const rows = metricsDb.raw
      .prepare("SELECT * FROM metrics WHERE name = 'search.fts_ms'")
      .all() as any[];
    expect(rows.length).toBeGreaterThan(0);
    expect(rows[0].type).toBe('histogram');
  });
});

describe('search modes', () => {
  let db: Database;
  let tmpDir: string;

  beforeEach(() => {
    tmpDir = mkdtempSync(join(tmpdir(), 'search-modes-'));
    db = new Database(join(tmpDir, 'test.sqlite'));
    db.upsertSession({
      id: 's1',
      source: 'codex',
      startTime: '2026-01-01T10:00:00Z',
      cwd: '/p',
      messageCount: 5,
      userMessageCount: 2,
      assistantMessageCount: 0,
      toolMessageCount: 0,
      systemMessageCount: 0,
      filePath: '/f1',
      sizeBytes: 100,
    });
    db.indexSessionContent('s1', [
      {
        role: 'user',
        content: 'Fix the SSL certificate error in nginx config',
      },
    ]);
    // Save an insight for FTS insight fallback tests
    db.saveInsightText(
      'ins1',
      'Always use HTTPS for production deployments',
      'devops',
      'ssl',
    );
  });

  afterEach(() => {
    db.close();
    rmSync(tmpDir, { recursive: true });
  });

  it('mode=keyword uses only FTS, not vector', async () => {
    const result = await handleSearch(db, {
      query: 'SSL certificate',
      mode: 'keyword',
    });
    expect(result.searchModes).toContain('keyword');
    expect(result.searchModes).not.toContain('semantic');
    expect(result.results.length).toBeGreaterThan(0);
    expect(result.results[0].matchType).toBe('keyword');
  });

  it('mode=semantic with no vectorStore returns empty results', async () => {
    const result = await handleSearch(
      db,
      { query: 'SSL certificate', mode: 'semantic' },
      {},
    );
    // No vectorStore/embed provided → semantic search skipped entirely
    expect(result.searchModes).not.toContain('semantic');
    expect(result.searchModes).not.toContain('keyword');
    expect(result.results).toHaveLength(0);
  });

  it('FTS insight fallback when no vectorStore', async () => {
    const result = await handleSearch(db, { query: 'HTTPS production' }, {});
    // No vectorStore → insights should be found via FTS fallback
    expect(result.insightResults).toBeDefined();
    expect(result.insightResults!.length).toBeGreaterThan(0);
    expect(result.insightResults![0]).toContain('HTTPS');
  });

  it('warning when embedding unavailable in hybrid mode', async () => {
    const result = await handleSearch(db, { query: 'SSL certificate' }, {});
    // Default mode is hybrid, no vectorStore provided
    expect(result.warning).toContain('Embedding provider unavailable');
    expect(result.warning).toContain('keyword-only');
  });

  it('short query < 3 chars skips keyword search', async () => {
    const result = await handleSearch(db, { query: 'SS' }, {});
    expect(result.searchModes).not.toContain('keyword');
    expect(result.results).toHaveLength(0);
  });

  it('short query < 2 chars skips both keyword and semantic', async () => {
    const result = await handleSearch(db, { query: 'S' }, {});
    expect(result.searchModes).toHaveLength(0);
    expect(result.results).toHaveLength(0);
    expect(result.warning).toContain('at least 3 characters');
  });

  it('UUID direct lookup finds matching session', async () => {
    const uuid = '12345678-1234-1234-1234-123456789abc';
    db.upsertSession({
      id: uuid,
      source: 'claude-code',
      startTime: '2026-01-03T10:00:00Z',
      cwd: '/projects/test',
      messageCount: 10,
      userMessageCount: 5,
      assistantMessageCount: 3,
      toolMessageCount: 2,
      systemMessageCount: 0,
      filePath: '/f-uuid',
      sizeBytes: 200,
    });

    const result = await handleSearch(db, { query: uuid });
    expect(result.searchModes).toEqual(['id']);
    expect(result.results).toHaveLength(1);
    expect(result.results[0].session.id).toBe(uuid);
    expect(result.results[0].score).toBe(1);
  });

  it('UUID direct lookup returns warning for non-existent session', async () => {
    const uuid = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee';
    const result = await handleSearch(db, { query: uuid });
    expect(result.searchModes).toEqual(['id']);
    expect(result.results).toHaveLength(0);
    expect(result.warning).toContain('No session found');
  });
});
