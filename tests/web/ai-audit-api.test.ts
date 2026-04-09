import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { AiAuditQuery, AiAuditWriter } from '../../src/core/ai-audit.js';
import { DEFAULT_AI_AUDIT_CONFIG } from '../../src/core/config.js';
import { Database } from '../../src/core/db.js';
import { createApp } from '../../src/web.js';

describe('AI Audit API', () => {
  let db: Database;
  let rawDb: ReturnType<Database['getRawDb']>;
  let writer: AiAuditWriter;
  let auditQuery: AiAuditQuery;

  beforeEach(() => {
    db = new Database(':memory:');
    rawDb = db.getRawDb();
    writer = new AiAuditWriter(rawDb, DEFAULT_AI_AUDIT_CONFIG);
    auditQuery = new AiAuditQuery(rawDb);
  });

  afterEach(() => {
    db.close();
  });

  describe('GET /api/ai/audit', () => {
    it('returns 501 when auditQuery not configured', async () => {
      const app = createApp(db);
      const res = await app.request('/api/ai/audit');
      expect(res.status).toBe(501);
      const body = await res.json();
      expect(body.error).toBe('Audit not configured');
    });

    it('returns records when configured', async () => {
      writer.record({
        caller: 'title',
        operation: 'generate',
        durationMs: 100,
        model: 'qwen2.5:3b',
      });
      writer.record({
        caller: 'viking',
        operation: 'pushSession',
        durationMs: 200,
      });

      const app = createApp(db, { auditQuery });
      const res = await app.request('/api/ai/audit');
      expect(res.status).toBe(200);
      const body = await res.json();
      expect(body.records).toHaveLength(2);
      expect(body.total).toBe(2);
    });

    it('supports caller filter', async () => {
      writer.record({
        caller: 'title',
        operation: 'generate',
        durationMs: 100,
      });
      writer.record({
        caller: 'viking',
        operation: 'pushSession',
        durationMs: 200,
      });

      const app = createApp(db, { auditQuery });
      const res = await app.request('/api/ai/audit?caller=title');
      const body = await res.json();
      expect(body.records).toHaveLength(1);
      expect(body.records[0].caller).toBe('title');
    });

    it('supports pagination', async () => {
      for (let i = 0; i < 5; i++) {
        writer.record({
          caller: 'title',
          operation: 'generate',
          durationMs: i * 10,
        });
      }

      const app = createApp(db, { auditQuery });
      const res = await app.request('/api/ai/audit?limit=2&offset=0');
      const body = await res.json();
      expect(body.records).toHaveLength(2);
      expect(body.total).toBe(5);
    });

    it('returns 401 without bearer token when token is configured', async () => {
      const app = createApp(db, {
        auditQuery,
        settings: { httpBearerToken: 'secret-token-123' },
      });
      const res = await app.request('/api/ai/audit');
      expect(res.status).toBe(401);
    });

    it('returns 200 with correct bearer token', async () => {
      writer.record({
        caller: 'title',
        operation: 'generate',
        durationMs: 100,
      });

      const app = createApp(db, {
        auditQuery,
        settings: { httpBearerToken: 'secret-token-123' },
      });
      const res = await app.request('/api/ai/audit', {
        headers: { Authorization: 'Bearer secret-token-123' },
      });
      expect(res.status).toBe(200);
      const body = await res.json();
      expect(body.records).toHaveLength(1);
    });
  });

  describe('GET /api/ai/audit/:id', () => {
    it('returns 501 when auditQuery not configured', async () => {
      const app = createApp(db);
      const res = await app.request('/api/ai/audit/1');
      expect(res.status).toBe(501);
    });

    it('returns 404 for missing record', async () => {
      const app = createApp(db, { auditQuery });
      const res = await app.request('/api/ai/audit/999');
      expect(res.status).toBe(404);
      const body = await res.json();
      expect(body.error).toBe('not found');
    });

    it('returns a single record by id', async () => {
      const id = writer.record({
        caller: 'title',
        operation: 'generate',
        durationMs: 150,
        model: 'qwen2.5:3b',
      });

      const app = createApp(db, { auditQuery });
      const res = await app.request(`/api/ai/audit/${id}`);
      expect(res.status).toBe(200);
      const body = await res.json();
      expect(body.id).toBe(id);
      expect(body.caller).toBe('title');
      expect(body.model).toBe('qwen2.5:3b');
    });
  });

  describe('GET /api/ai/stats', () => {
    it('returns 501 when auditQuery not configured', async () => {
      const app = createApp(db);
      const res = await app.request('/api/ai/stats');
      expect(res.status).toBe(501);
    });

    it('returns stats shape', async () => {
      writer.record({
        caller: 'title',
        operation: 'generate',
        durationMs: 100,
        promptTokens: 500,
        completionTokens: 80,
      });
      writer.record({
        caller: 'viking',
        operation: 'pushSession',
        durationMs: 200,
      });

      const app = createApp(db, { auditQuery });
      const res = await app.request('/api/ai/stats');
      expect(res.status).toBe(200);
      const body = await res.json();
      expect(body).toHaveProperty('timeRange');
      expect(body).toHaveProperty('totals');
      expect(body).toHaveProperty('byCaller');
      expect(body).toHaveProperty('byModel');
      expect(body).toHaveProperty('hourly');
      expect(body.totals.requests).toBe(2);
    });
  });

  describe('Viking Observer Proxy', () => {
    it('GET /api/viking/observer returns 501 when Viking not configured', async () => {
      const app = createApp(db);
      const res = await app.request('/api/viking/observer');
      expect(res.status).toBe(501);
      const body = await res.json();
      expect(body.error).toBe('Viking not configured');
    });

    it('GET /api/viking/observer/queue returns 501 when Viking not configured', async () => {
      const app = createApp(db);
      const res = await app.request('/api/viking/observer/queue');
      expect(res.status).toBe(501);
    });

    it('GET /api/viking/observer/vlm returns 501 when Viking not configured', async () => {
      const app = createApp(db);
      const res = await app.request('/api/viking/observer/vlm');
      expect(res.status).toBe(501);
    });

    it('GET /api/viking/observer/vikingdb returns 501 when Viking not configured', async () => {
      const app = createApp(db);
      const res = await app.request('/api/viking/observer/vikingdb');
      expect(res.status).toBe(501);
    });

    it('GET /api/viking/observer/transaction returns 501 when Viking not configured', async () => {
      const app = createApp(db);
      const res = await app.request('/api/viking/observer/transaction');
      expect(res.status).toBe(501);
    });
  });
});
