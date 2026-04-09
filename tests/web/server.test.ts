import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import type { SessionInfo } from '../../src/adapters/types.js';
import { Database } from '../../src/core/db.js';
import { createApp } from '../../src/web.js';

const mockSession: SessionInfo = {
  id: 'session-001',
  source: 'codex',
  startTime: '2026-01-01T10:00:00.000Z',
  endTime: '2026-01-01T11:00:00.000Z',
  cwd: '/Users/test/project',
  project: 'my-project',
  model: 'gpt-4o',
  messageCount: 20,
  userMessageCount: 10,
  assistantMessageCount: 0,
  toolMessageCount: 0,
  systemMessageCount: 0,
  summary: 'Fix login bug',
  filePath: '/Users/test/.codex/sessions/rollout-123.jsonl',
  sizeBytes: 50000,
};

describe('Web Server', () => {
  let db: Database;
  let tmpDir: string;
  let app: ReturnType<typeof createApp>;

  beforeEach(() => {
    tmpDir = mkdtempSync(join(tmpdir(), 'engram-web-test-'));
    db = new Database(join(tmpDir, 'test.sqlite'));
    app = createApp(db);
  });

  afterEach(() => {
    db.close();
    rmSync(tmpDir, { recursive: true });
  });

  it('GET /api/sync/status returns node info', async () => {
    const res = await app.request('/api/sync/status');
    expect(res.status).toBe(200);
    const body = await res.json();
    expect(body).toHaveProperty('sessionCount');
    expect(body).toHaveProperty('nodeName');
  });

  it('GET /api/sessions returns session list', async () => {
    db.upsertSession(mockSession);
    db.upsertSession({
      ...mockSession,
      id: 'session-002',
      source: 'claude-code',
    });
    const res = await app.request('/api/sessions');
    expect(res.status).toBe(200);
    const body = await res.json();
    expect(body.sessions).toHaveLength(2);
  });

  it('GET /api/sessions supports source filter', async () => {
    db.upsertSession(mockSession);
    db.upsertSession({
      ...mockSession,
      id: 'session-002',
      source: 'claude-code',
    });
    const res = await app.request('/api/sessions?source=codex');
    const body = await res.json();
    expect(body.sessions).toHaveLength(1);
    expect(body.sessions[0].source).toBe('codex');
  });

  it('GET /api/sessions/:id returns single session', async () => {
    db.upsertSession(mockSession);
    const res = await app.request('/api/sessions/session-001');
    expect(res.status).toBe(200);
    const body = await res.json();
    expect(body.id).toBe('session-001');
  });

  it('GET /api/sessions/:id returns 404 for missing session', async () => {
    const res = await app.request('/api/sessions/nonexistent');
    expect(res.status).toBe(404);
  });

  it('GET /api/search returns FTS5 results', async () => {
    db.upsertSession(mockSession);
    db.indexSessionContent('session-001', [
      {
        role: 'user',
        content: 'Fix the SSL certificate error in nginx config',
      },
    ]);
    const res = await app.request('/api/search?q=SSL');
    expect(res.status).toBe(200);
    const body = await res.json();
    expect(body.results.length).toBeGreaterThan(0);
  });

  it('GET /api/search returns warning for short query', async () => {
    const res = await app.request('/api/search?q=ab');
    const body = await res.json();
    expect(body.warning).toBeTruthy();
  });

  it('GET /api/stats returns grouped statistics', async () => {
    db.upsertSession(mockSession);
    db.upsertSession({
      ...mockSession,
      id: 'session-002',
      source: 'claude-code',
    });
    const res = await app.request('/api/stats');
    expect(res.status).toBe(200);
    const body = await res.json();
    expect(body.groups.length).toBeGreaterThan(0);
    expect(body.totalSessions).toBe(2);
  });

  it('GET /api/sync/sessions returns sessions since timestamp', async () => {
    db.upsertSession(mockSession);
    const yesterday = new Date(Date.now() - 86400000).toISOString();
    const res = await app.request(`/api/sync/sessions?since=${yesterday}`);
    expect(res.status).toBe(200);
    const body = await res.json();
    expect(body.sessions).toHaveLength(1);
  });

  it('GET /api/sync/sessions requires since parameter', async () => {
    const res = await app.request('/api/sync/sessions');
    expect(res.status).toBe(400);
  });

  it('GET /api/sync/sessions serves sessions with composite cursor semantics', async () => {
    db.upsertAuthoritativeSnapshot({
      id: 'sess-001',
      source: 'codex',
      authoritativeNode: 'node-a',
      syncVersion: 1,
      snapshotHash: 'hash-1',
      indexedAt: '2026-03-18T12:00:00Z',
      sourceLocator: '/remote/sess-001.jsonl',
      startTime: '2026-03-18T12:00:00Z',
      cwd: '/repo',
      messageCount: 2,
      userMessageCount: 1,
      assistantMessageCount: 1,
      toolMessageCount: 0,
      systemMessageCount: 0,
    } as any);
    db.upsertAuthoritativeSnapshot({
      id: 'sess-002',
      source: 'codex',
      authoritativeNode: 'node-a',
      syncVersion: 1,
      snapshotHash: 'hash-2',
      indexedAt: '2026-03-18T12:00:00Z',
      sourceLocator: '/remote/sess-002.jsonl',
      startTime: '2026-03-18T12:00:00Z',
      cwd: '/repo',
      messageCount: 2,
      userMessageCount: 1,
      assistantMessageCount: 1,
      toolMessageCount: 0,
      systemMessageCount: 0,
    } as any);
    db.upsertAuthoritativeSnapshot({
      id: 'sess-003',
      source: 'codex',
      authoritativeNode: 'node-a',
      syncVersion: 1,
      snapshotHash: 'hash-3',
      indexedAt: '2026-03-18T12:01:00Z',
      sourceLocator: '/remote/sess-003.jsonl',
      startTime: '2026-03-18T12:01:00Z',
      cwd: '/repo',
      messageCount: 2,
      userMessageCount: 1,
      assistantMessageCount: 1,
      toolMessageCount: 0,
      systemMessageCount: 0,
    } as any);

    const res = await app.request(
      '/api/sync/sessions?cursor_indexed_at=2026-03-18T12:00:00Z&cursor_id=sess-001&limit=10',
    );
    expect(res.status).toBe(200);
    const body = await res.json();
    expect(body.sessions.map((s: { id: string }) => s.id)).toEqual([
      'sess-002',
      'sess-003',
    ]);
  });

  it('GET /api/search/semantic returns 501 when vector store not configured', async () => {
    const res = await app.request('/api/search/semantic?q=test+query');
    expect(res.status).toBe(501);
    const body = await res.json();
    expect(body.error).toContain('not available');
  });
});

describe('POST /api/summary', () => {
  let db: Database;
  let tmpDir: string;
  let app: ReturnType<typeof createApp>;

  beforeEach(() => {
    tmpDir = mkdtempSync(join(tmpdir(), 'engram-summary-test-'));
    db = new Database(join(tmpDir, 'test.sqlite'));
    app = createApp(db);
  });

  afterEach(() => {
    db.close();
    rmSync(tmpDir, { recursive: true });
  });

  it('returns 400 when sessionId is missing', async () => {
    const res = await app.request('/api/summary', {
      method: 'POST',
      body: JSON.stringify({}),
      headers: { 'Content-Type': 'application/json' },
    });
    expect(res.status).toBe(400);
    const json = (await res.json()) as { error: string };
    expect(json.error).toContain('sessionId');
  });

  it('returns 404 when session not found', async () => {
    const res = await app.request('/api/summary', {
      method: 'POST',
      body: JSON.stringify({ sessionId: 'nonexistent-id' }),
      headers: { 'Content-Type': 'application/json' },
    });
    expect(res.status).toBe(404);
  });

  it('returns 500 when no API key configured', async () => {
    db.upsertSession(mockSession);
    const res = await app.request('/api/summary', {
      method: 'POST',
      body: JSON.stringify({ sessionId: 'session-001' }),
      headers: { 'Content-Type': 'application/json' },
    });
    expect(res.status).toBe(500);
    const json = (await res.json()) as { error: string };
    expect(json.error).toContain('API key');
  });
});

// --- CIDR utilities ---
import { ipMatchesCIDR, ipToUint32, parseCIDR } from '../../src/web.js';

describe('CIDR utilities', () => {
  it('ipToUint32 converts correctly', () => {
    expect(ipToUint32('0.0.0.0')).toBe(0);
    expect(ipToUint32('255.255.255.255')).toBe(0xffffffff);
    expect(ipToUint32('10.0.0.1')).toBe(((10 << 24) | 1) >>> 0);
    expect(ipToUint32('192.168.1.100')).toBe(
      ((192 << 24) | (168 << 16) | (1 << 8) | 100) >>> 0,
    );
  });

  it('parseCIDR parses network and mask', () => {
    const c = parseCIDR('10.0.0.0/8');
    expect(c.network).toBe(ipToUint32('10.0.0.0'));
    expect(c.mask).toBe(0xff000000);

    const c2 = parseCIDR('192.168.1.0/24');
    expect(c2.network).toBe(ipToUint32('192.168.1.0'));
    expect(c2.mask).toBe(0xffffff00);
  });

  it('ipMatchesCIDR matches IPs within range', () => {
    const cidrs = [parseCIDR('10.0.0.0/8')];
    expect(ipMatchesCIDR('10.1.2.3', cidrs)).toBe(true);
    expect(ipMatchesCIDR('10.255.255.255', cidrs)).toBe(true);
    expect(ipMatchesCIDR('11.0.0.1', cidrs)).toBe(false);
    expect(ipMatchesCIDR('192.168.1.1', cidrs)).toBe(false);
  });

  it('ipMatchesCIDR always allows loopback', () => {
    const cidrs = [parseCIDR('10.0.0.0/8')];
    expect(ipMatchesCIDR('127.0.0.1', cidrs)).toBe(true);
    expect(ipMatchesCIDR('::1', cidrs)).toBe(true);
    expect(ipMatchesCIDR('::ffff:127.0.0.1', cidrs)).toBe(true);
  });

  it('ipMatchesCIDR handles IPv4-mapped IPv6', () => {
    const cidrs = [parseCIDR('10.0.0.0/8')];
    expect(ipMatchesCIDR('::ffff:10.0.0.5', cidrs)).toBe(true);
    expect(ipMatchesCIDR('::ffff:192.168.1.1', cidrs)).toBe(false);
  });

  it('ipMatchesCIDR supports multiple CIDRs', () => {
    const cidrs = [parseCIDR('10.0.0.0/8'), parseCIDR('192.168.0.0/16')];
    expect(ipMatchesCIDR('10.1.1.1', cidrs)).toBe(true);
    expect(ipMatchesCIDR('192.168.5.5', cidrs)).toBe(true);
    expect(ipMatchesCIDR('172.16.0.1', cidrs)).toBe(false);
  });
});
