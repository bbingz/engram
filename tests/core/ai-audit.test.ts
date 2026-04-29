import Database from 'better-sqlite3';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { AiAuditQuery, AiAuditWriter } from '../../src/core/ai-audit.js';
import { DEFAULT_AI_AUDIT_CONFIG } from '../../src/core/config.js';

const TABLE_DDL = `CREATE TABLE ai_audit_log (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  ts TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%f','now')),
  trace_id TEXT, caller TEXT NOT NULL, operation TEXT NOT NULL,
  request_source TEXT, method TEXT, url TEXT, status_code INTEGER,
  duration_ms INTEGER, model TEXT, provider TEXT,
  prompt_tokens INTEGER, completion_tokens INTEGER, total_tokens INTEGER,
  request_body TEXT, response_body TEXT, error TEXT, session_id TEXT, meta TEXT
)`;

describe('AiAuditWriter', () => {
  let db: Database.Database;
  let writer: AiAuditWriter;

  beforeEach(() => {
    db = new Database(':memory:');
    db.exec(TABLE_DDL);
    writer = new AiAuditWriter(db, DEFAULT_AI_AUDIT_CONFIG);
  });

  afterEach(() => {
    try {
      db.close();
    } catch {
      /* already closed */
    }
  });

  it('records a basic entry and returns the inserted id', () => {
    const id = writer.record({
      caller: 'title',
      operation: 'generate',
      durationMs: 100,
      model: 'qwen2.5:3b',
      provider: 'ollama',
    });
    expect(id).toBeGreaterThan(0);
    const row = db
      .prepare('SELECT * FROM ai_audit_log WHERE id = ?')
      .get(id) as any;
    expect(row.caller).toBe('title');
    expect(row.model).toBe('qwen2.5:3b');
    expect(row.duration_ms).toBe(100);
  });

  it('records token counts', () => {
    const id = writer.record({
      caller: 'summary',
      operation: 'summarize',
      durationMs: 500,
      promptTokens: 1000,
      completionTokens: 200,
      totalTokens: 1200,
    });
    const row = db
      .prepare('SELECT * FROM ai_audit_log WHERE id = ?')
      .get(id) as any;
    expect(row.prompt_tokens).toBe(1000);
    expect(row.completion_tokens).toBe(200);
    expect(row.total_tokens).toBe(1200);
  });

  it('does not store bodies when logBodies is false', () => {
    const id = writer.record({
      caller: 'title',
      operation: 'generate',
      durationMs: 100,
      requestBody: { prompt: 'hello' },
      responseBody: { text: 'world' },
    });
    const row = db
      .prepare('SELECT * FROM ai_audit_log WHERE id = ?')
      .get(id) as any;
    expect(row.request_body).toBeNull();
    expect(row.response_body).toBeNull();
  });

  it('stores bodies when logBodies is true', () => {
    const w = new AiAuditWriter(db, {
      ...DEFAULT_AI_AUDIT_CONFIG,
      logBodies: true,
    });
    const id = w.record({
      caller: 'title',
      operation: 'generate',
      durationMs: 100,
      requestBody: { prompt: 'hello' },
      responseBody: { text: 'world' },
    });
    const row = db
      .prepare('SELECT * FROM ai_audit_log WHERE id = ?')
      .get(id) as any;
    expect(row.request_body).toContain('hello');
    expect(row.response_body).toContain('world');
  });

  it('truncates bodies to maxBodySize', () => {
    const w = new AiAuditWriter(db, {
      ...DEFAULT_AI_AUDIT_CONFIG,
      logBodies: true,
      maxBodySize: 20,
    });
    const id = w.record({
      caller: 'title',
      operation: 'generate',
      durationMs: 100,
      requestBody: 'a'.repeat(100),
    });
    const row = db
      .prepare('SELECT * FROM ai_audit_log WHERE id = ?')
      .get(id) as any;
    expect(row.request_body.length).toBeLessThanOrEqual(35); // 20 + '...[truncated]'
  });

  it('sanitizes URLs (strips API keys)', () => {
    const id = writer.record({
      caller: 'summary',
      operation: 'summarize',
      durationMs: 100,
      url: 'https://api.example.com/v1?key=sk-abc123def456ghi789jkl012',
    });
    const row = db
      .prepare('SELECT * FROM ai_audit_log WHERE id = ?')
      .get(id) as any;
    expect(row.url).not.toContain('sk-abc123def456ghi789jkl012');
  });

  it('never throws on record failure', () => {
    db.close();
    expect(() =>
      writer.record({
        caller: 'title',
        operation: 'generate',
        durationMs: 100,
      }),
    ).not.toThrow();
    expect(
      writer.record({
        caller: 'title',
        operation: 'generate',
        durationMs: 100,
      }),
    ).toBe(-1);
  });

  it('logs to console.error when record fails (not silent)', () => {
    const spy = vi.spyOn(console, 'error').mockImplementation(() => {});
    db.close();
    writer.record({
      caller: 'title',
      operation: 'generate',
      durationMs: 100,
    });
    expect(spy).toHaveBeenCalledWith(
      '[ai-audit] record failed',
      expect.any(Error),
    );
    spy.mockRestore();
  });

  it('emits entry event after recording', () => {
    const handler = vi.fn();
    writer.on('entry', handler);
    writer.record({ caller: 'title', operation: 'generate', durationMs: 100 });
    expect(handler).toHaveBeenCalledWith(
      expect.objectContaining({ caller: 'title' }),
    );
  });

  it('skips recording when disabled', () => {
    const w = new AiAuditWriter(db, {
      ...DEFAULT_AI_AUDIT_CONFIG,
      enabled: false,
    });
    const id = w.record({
      caller: 'title',
      operation: 'generate',
      durationMs: 100,
    });
    expect(id).toBe(-1);
    const count = db
      .prepare('SELECT COUNT(*) as c FROM ai_audit_log')
      .get() as any;
    expect(count.c).toBe(0);
  });

  it('stores meta as JSON', () => {
    const id = writer.record({
      caller: 'semantic_index',
      operation: 'pushSession',
      durationMs: 5000,
      meta: { messageCount: 50 },
    });
    const row = db
      .prepare('SELECT * FROM ai_audit_log WHERE id = ?')
      .get(id) as any;
    expect(JSON.parse(row.meta)).toEqual({ messageCount: 50 });
  });

  it('cleanup deletes old records', () => {
    // Insert a record with old timestamp
    db.prepare(`INSERT INTO ai_audit_log (ts, caller, operation, duration_ms)
      VALUES (datetime('now', '-60 days'), 'title', 'generate', 100)`).run();
    writer.record({ caller: 'title', operation: 'generate', durationMs: 100 });
    expect(writer.cleanup(30)).toBe(1);
    const count = db
      .prepare('SELECT COUNT(*) as c FROM ai_audit_log')
      .get() as any;
    expect(count.c).toBe(1); // only the recent one remains
  });
});

describe('AiAuditQuery', () => {
  let db: Database.Database;
  let writer: AiAuditWriter;
  let query: AiAuditQuery;

  beforeEach(() => {
    db = new Database(':memory:');
    db.exec(TABLE_DDL);
    writer = new AiAuditWriter(db, DEFAULT_AI_AUDIT_CONFIG);
    query = new AiAuditQuery(db);
  });

  afterEach(() => {
    try {
      db.close();
    } catch {
      /* already closed */
    }
  });

  it('list returns paginated records', () => {
    for (let i = 0; i < 10; i++) {
      writer.record({
        caller: 'title',
        operation: 'generate',
        durationMs: 100 + i,
      });
    }
    const result = query.list({ limit: 3, offset: 0 });
    expect(result.records).toHaveLength(3);
    expect(result.total).toBe(10);
  });

  it('list filters by caller', () => {
    writer.record({ caller: 'title', operation: 'generate', durationMs: 100 });
    writer.record({
      caller: 'semantic_index',
      operation: 'find',
      durationMs: 200,
    });
    const result = query.list({ caller: 'semantic_index' });
    expect(result.records).toHaveLength(1);
    expect(result.records[0].caller).toBe('semantic_index');
  });

  it('list filters by hasError', () => {
    writer.record({ caller: 'title', operation: 'generate', durationMs: 100 });
    writer.record({
      caller: 'title',
      operation: 'generate',
      durationMs: 100,
      error: 'timeout',
    });
    const result = query.list({ hasError: true });
    expect(result.records).toHaveLength(1);
    expect(result.records[0].error).toBe('timeout');
  });

  it('list from parameter is exclusive', () => {
    writer.record({ caller: 'title', operation: 'generate', durationMs: 100 });
    const { records } = query.list({});
    const ts = records[0].ts;
    const result = query.list({ from: ts });
    expect(result.records).toHaveLength(0); // from is exclusive, so same ts excluded
  });

  it('get returns single record', () => {
    const id = writer.record({
      caller: 'title',
      operation: 'generate',
      durationMs: 100,
    });
    const record = query.get(id);
    expect(record).not.toBeNull();
    expect(record?.caller).toBe('title');
  });

  it('get returns null for missing id', () => {
    expect(query.get(9999)).toBeNull();
  });

  it('stats returns aggregated data', () => {
    writer.record({
      caller: 'title',
      operation: 'generate',
      durationMs: 100,
      model: 'qwen',
      promptTokens: 500,
      completionTokens: 100,
      totalTokens: 600,
    });
    writer.record({
      caller: 'semantic_index',
      operation: 'find',
      durationMs: 200,
    });
    writer.record({
      caller: 'title',
      operation: 'generate',
      durationMs: 300,
      model: 'qwen',
      error: 'fail',
    });

    const s = query.stats();
    expect(s.totals.requests).toBe(3);
    expect(s.totals.errors).toBe(1);
    expect(s.totals.promptTokens).toBe(500);
    expect(s.byCaller.title.requests).toBe(2);
    expect(s.byCaller.semantic_index.requests).toBe(1);
    expect(s.byModel.qwen).toBeDefined();
  });
});
