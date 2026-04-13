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

// --- Additional API endpoint coverage ---

describe('Hono API server — additional endpoints', () => {
  let db: Database;
  let tmpDir: string;
  let app: ReturnType<typeof createApp>;

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

  beforeEach(() => {
    tmpDir = mkdtempSync(join(tmpdir(), 'engram-web-extra-'));
    db = new Database(join(tmpDir, 'test.sqlite'));
    app = createApp(db);
  });

  afterEach(() => {
    db.close();
    rmSync(tmpDir, { recursive: true });
  });

  it('GET /api/status returns general status', async () => {
    db.upsertSession(mockSession);
    const res = await app.request('/api/status');
    expect(res.status).toBe(200);
    const body = await res.json();
    expect(body).toHaveProperty('totalSessions');
    expect(body).toHaveProperty('sourceCount');
    expect(body).toHaveProperty('projectCount');
    expect(body).toHaveProperty('sources');
    expect(body).toHaveProperty('projects');
    expect(body).toHaveProperty('embeddingAvailable');
    expect(body.totalSessions).toBe(1);
    expect(body.embeddingAvailable).toBe(false);
  });

  it('GET /api/sources returns source list with stats', async () => {
    db.upsertSession(mockSession);
    const res = await app.request('/api/sources');
    expect(res.status).toBe(200);
    const body = await res.json();
    expect(Array.isArray(body)).toBe(true);
    expect(body.length).toBeGreaterThan(0);
    expect(body[0]).toHaveProperty('name');
    expect(body[0]).toHaveProperty('sessionCount');
    expect(body[0]).toHaveProperty('latestIndexed');
  });

  it('GET /api/costs returns cost summary', async () => {
    db.upsertSession(mockSession);
    const res = await app.request('/api/costs');
    expect(res.status).toBe(200);
    const body = await res.json();
    expect(body).toHaveProperty('totalCostUsd');
  });

  it('GET /api/costs/sessions returns top sessions by cost', async () => {
    db.upsertSession(mockSession);
    const res = await app.request('/api/costs/sessions?limit=5');
    expect(res.status).toBe(200);
    const body = await res.json();
    expect(body).toHaveProperty('sessions');
    expect(Array.isArray(body.sessions)).toBe(true);
  });

  it('GET /api/file-activity returns file activity list', async () => {
    db.upsertSession(mockSession);
    const res = await app.request('/api/file-activity');
    expect(res.status).toBe(200);
    const body = await res.json();
    expect(body).toHaveProperty('files');
    expect(body).toHaveProperty('totalFiles');
    expect(Array.isArray(body.files)).toBe(true);
  });

  it('GET /api/tool-analytics returns tool usage data', async () => {
    db.upsertSession(mockSession);
    const res = await app.request('/api/tool-analytics');
    expect(res.status).toBe(200);
    const body = await res.json();
    expect(body).toHaveProperty('tools');
  });

  it('GET /api/project-aliases returns alias list', async () => {
    const res = await app.request('/api/project-aliases');
    expect(res.status).toBe(200);
    const body = await res.json();
    expect(Array.isArray(body)).toBe(true);
  });

  it('POST /api/project-aliases creates an alias', async () => {
    const res = await app.request('/api/project-aliases', {
      method: 'POST',
      body: JSON.stringify({ alias: 'eng', canonical: 'engram' }),
      headers: { 'Content-Type': 'application/json' },
    });
    expect(res.status).toBe(200);
    const body = await res.json();
    expect(body).toHaveProperty('added');
    expect(body.added.alias).toBe('eng');
    expect(body.added.canonical).toBe('engram');

    // Verify it shows in list
    const listRes = await app.request('/api/project-aliases');
    const list = await listRes.json();
    expect(list.length).toBeGreaterThan(0);
  });

  it('POST /api/project-aliases returns 400 when fields missing', async () => {
    const res = await app.request('/api/project-aliases', {
      method: 'POST',
      body: JSON.stringify({ alias: 'eng' }),
      headers: { 'Content-Type': 'application/json' },
    });
    expect(res.status).toBe(400);
  });

  it('DELETE /api/project-aliases removes an alias', async () => {
    // First add one
    await app.request('/api/project-aliases', {
      method: 'POST',
      body: JSON.stringify({ alias: 'eng', canonical: 'engram' }),
      headers: { 'Content-Type': 'application/json' },
    });

    const res = await app.request('/api/project-aliases', {
      method: 'DELETE',
      body: JSON.stringify({ alias: 'eng', canonical: 'engram' }),
      headers: { 'Content-Type': 'application/json' },
    });
    expect(res.status).toBe(200);
    const body = await res.json();
    expect(body).toHaveProperty('removed');
  });

  it('DELETE /api/project-aliases returns 400 when fields missing', async () => {
    const res = await app.request('/api/project-aliases', {
      method: 'DELETE',
      body: JSON.stringify({}),
      headers: { 'Content-Type': 'application/json' },
    });
    expect(res.status).toBe(400);
  });

  it('GET /api/repos returns repo list', async () => {
    const res = await app.request('/api/repos');
    expect(res.status).toBe(200);
    const body = await res.json();
    expect(body).toHaveProperty('repos');
    expect(Array.isArray(body.repos)).toBe(true);
  });

  it('GET /api/usage returns usage snapshots', async () => {
    const res = await app.request('/api/usage');
    expect(res.status).toBe(200);
    const body = await res.json();
    expect(body).toHaveProperty('usage');
    expect(Array.isArray(body.usage)).toBe(true);
  });

  it('GET /api/live returns live sessions list', async () => {
    const res = await app.request('/api/live');
    expect(res.status).toBe(200);
    const body = await res.json();
    expect(body).toHaveProperty('sessions');
    expect(body).toHaveProperty('count');
    expect(Array.isArray(body.sessions)).toBe(true);
  });

  it('GET /api/monitor/alerts returns alerts list', async () => {
    const res = await app.request('/api/monitor/alerts');
    expect(res.status).toBe(200);
    const body = await res.json();
    expect(body).toHaveProperty('alerts');
    expect(body).toHaveProperty('total');
    expect(Array.isArray(body.alerts)).toBe(true);
  });

  it('POST /api/monitor/alerts/:id/dismiss dismisses an alert', async () => {
    const res = await app.request('/api/monitor/alerts/alert-1/dismiss', {
      method: 'POST',
    });
    expect(res.status).toBe(200);
    const body = await res.json();
    expect(body).toHaveProperty('dismissed', 'alert-1');
  });

  it('GET /api/search/status returns embedding status', async () => {
    const res = await app.request('/api/search/status');
    expect(res.status).toBe(200);
    const body = await res.json();
    expect(body).toHaveProperty('available');
    expect(body).toHaveProperty('embeddedCount');
    expect(body).toHaveProperty('totalSessions');
    expect(body).toHaveProperty('progress');
    expect(body.available).toBe(false);
  });

  it('GET /api/health/sources returns source health data', async () => {
    db.upsertSession(mockSession);
    const res = await app.request('/api/health/sources');
    expect(res.status).toBe(200);
    const body = await res.json();
    expect(body).toHaveProperty('sources');
    expect(body).toHaveProperty('summary');
    expect(body.summary).toHaveProperty('totalSources');
    expect(body.summary).toHaveProperty('activeSources');
    expect(Array.isArray(body.sources)).toBe(true);
  });

  it('GET /api/hygiene returns health check results', async () => {
    const res = await app.request('/api/hygiene');
    expect(res.status).toBe(200);
    const body = await res.json();
    expect(body).toHaveProperty('issues');
  });

  it('POST /api/session/:id/resume returns 404 for missing session', async () => {
    const res = await app.request('/api/session/nonexistent/resume', {
      method: 'POST',
    });
    expect(res.status).toBe(404);
  });

  it('POST /api/session/:id/resume returns resume command for existing session', async () => {
    db.upsertSession(mockSession);
    const res = await app.request('/api/session/session-001/resume', {
      method: 'POST',
    });
    expect(res.status).toBe(200);
    const body = await res.json();
    expect(body).toHaveProperty('command');
  });

  it('POST /api/handoff returns 400 when cwd missing', async () => {
    const res = await app.request('/api/handoff', {
      method: 'POST',
      body: JSON.stringify({}),
      headers: { 'Content-Type': 'application/json' },
    });
    expect(res.status).toBe(400);
    const body = await res.json();
    expect(body.error).toContain('cwd');
  });

  it('POST /api/link-sessions returns 400 when targetDir missing', async () => {
    const res = await app.request('/api/link-sessions', {
      method: 'POST',
      body: JSON.stringify({}),
      headers: { 'Content-Type': 'application/json' },
    });
    expect(res.status).toBe(400);
    const body = await res.json();
    expect(body.error).toContain('targetDir');
  });

  it('GET /api/ai/audit returns 501 when audit not configured', async () => {
    const res = await app.request('/api/ai/audit');
    expect(res.status).toBe(501);
  });

  it('GET /api/ai/stats returns 501 when audit not configured', async () => {
    const res = await app.request('/api/ai/stats');
    expect(res.status).toBe(501);
  });

  it('GET /api/ai/audit/:id returns 501 when audit not configured', async () => {
    const res = await app.request('/api/ai/audit/1');
    expect(res.status).toBe(501);
  });

  it('POST /api/sync/trigger returns 501 when sync not configured', async () => {
    const res = await app.request('/api/sync/trigger', { method: 'POST' });
    expect(res.status).toBe(501);
  });

  it('POST /api/log returns 400 with invalid body', async () => {
    const res = await app.request('/api/log', {
      method: 'POST',
      body: JSON.stringify({}),
      headers: { 'Content-Type': 'application/json' },
    });
    expect(res.status).toBe(400);
  });

  it('POST /api/log returns 200 with valid log entry', async () => {
    const res = await app.request('/api/log', {
      method: 'POST',
      body: JSON.stringify({
        level: 'info',
        module: 'test',
        message: 'hello from test',
      }),
      headers: { 'Content-Type': 'application/json' },
    });
    expect(res.status).toBe(200);
    const body = await res.json();
    expect(body.ok).toBe(true);
  });

  it('POST /api/log returns 400 with invalid level', async () => {
    const res = await app.request('/api/log', {
      method: 'POST',
      body: JSON.stringify({
        level: 'critical',
        module: 'test',
        message: 'bad level',
      }),
      headers: { 'Content-Type': 'application/json' },
    });
    expect(res.status).toBe(400);
  });

  it('GET /goto redirects to / when id is missing', async () => {
    const res = await app.request('/goto', { redirect: 'manual' });
    expect(res.status).toBe(302);
    expect(res.headers.get('location')).toBe('/');
  });

  it('GET /goto redirects to session when id exists', async () => {
    db.upsertSession(mockSession);
    const res = await app.request('/goto?id=session-001', {
      redirect: 'manual',
    });
    expect(res.status).toBe(302);
    expect(res.headers.get('location')).toBe('/session/session-001');
  });

  it('POST /api/dev/mock returns 403 when dev mode disabled', async () => {
    const res = await app.request('/api/dev/mock', { method: 'POST' });
    expect(res.status).toBe(403);
  });

  it('DELETE /api/dev/mock returns 403 when dev mode disabled', async () => {
    const res = await app.request('/api/dev/mock', { method: 'DELETE' });
    expect(res.status).toBe(403);
  });

  it('POST /api/lint returns 400 when cwd is missing', async () => {
    const res = await app.request('/api/lint', {
      method: 'POST',
      body: JSON.stringify({}),
      headers: { 'Content-Type': 'application/json' },
    });
    expect(res.status).toBe(400);
  });

  it('POST /api/lint returns 400 when cwd is relative', async () => {
    const res = await app.request('/api/lint', {
      method: 'POST',
      body: JSON.stringify({ cwd: 'relative/path' }),
      headers: { 'Content-Type': 'application/json' },
    });
    expect(res.status).toBe(400);
    const body = await res.json();
    expect(body.error).toContain('absolute');
  });

  it('GET /api/sessions supports limit and offset', async () => {
    db.upsertSession(mockSession);
    db.upsertSession({
      ...mockSession,
      id: 'session-002',
      source: 'claude-code',
    });
    db.upsertSession({
      ...mockSession,
      id: 'session-003',
      source: 'gemini-cli',
    });

    const res = await app.request('/api/sessions?limit=2&offset=0');
    expect(res.status).toBe(200);
    const body = await res.json();
    expect(body).toHaveProperty('offset', 0);
    expect(body).toHaveProperty('limit', 2);
    expect(body).toHaveProperty('hasMore');
    expect(body.sessions.length).toBeLessThanOrEqual(2);
  });

  it('GET /api/sessions supports project filter', async () => {
    db.upsertSession(mockSession);
    db.upsertSession({
      ...mockSession,
      id: 'session-002',
      project: 'other-project',
    });
    const res = await app.request('/api/sessions?project=my-project');
    expect(res.status).toBe(200);
    const body = await res.json();
    expect(
      body.sessions.every(
        (s: { project: string }) => s.project === 'my-project',
      ),
    ).toBe(true);
  });

  it('GET /api/costs supports since/until filters', async () => {
    db.upsertSession(mockSession);
    const res = await app.request(
      '/api/costs?since=2026-01-01&until=2026-12-31',
    );
    expect(res.status).toBe(200);
    const body = await res.json();
    expect(body).toHaveProperty('totalCostUsd');
  });

  it('GET /api/tool-analytics supports project filter', async () => {
    db.upsertSession(mockSession);
    const res = await app.request('/api/tool-analytics?project=my-project');
    expect(res.status).toBe(200);
    const body = await res.json();
    expect(body).toHaveProperty('tools');
  });

  it('GET /api/file-activity supports project and since filters', async () => {
    db.upsertSession(mockSession);
    const res = await app.request(
      '/api/file-activity?project=my-project&since=2026-01-01',
    );
    expect(res.status).toBe(200);
    const body = await res.json();
    expect(body).toHaveProperty('files');
    expect(body).toHaveProperty('totalFiles');
  });

  it('GET /api/stats supports group_by and since/until', async () => {
    db.upsertSession(mockSession);
    const res = await app.request(
      '/api/stats?group_by=project&since=2026-01-01&until=2026-12-31&exclude_noise=0',
    );
    expect(res.status).toBe(200);
    const body = await res.json();
    expect(body).toHaveProperty('groups');
    expect(body).toHaveProperty('totalSessions');
  });
});

// --- HTML route coverage ---
describe('HTML routes', () => {
  let db: Database;
  let tmpDir: string;
  let app: ReturnType<typeof createApp>;

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

  beforeEach(() => {
    tmpDir = mkdtempSync(join(tmpdir(), 'engram-html-test-'));
    db = new Database(join(tmpDir, 'test.sqlite'));
    app = createApp(db);
  });

  afterEach(() => {
    db.close();
    rmSync(tmpDir, { recursive: true });
  });

  it('GET / returns session list HTML', async () => {
    db.upsertSession(mockSession);
    const res = await app.request('/');
    expect(res.status).toBe(200);
    const html = await res.text();
    expect(html).toContain('<!DOCTYPE html>');
    expect(html).toContain('session-001');
  });

  it('GET / supports source and project filters', async () => {
    db.upsertSession(mockSession);
    const res = await app.request('/?source=codex&project=my-project');
    expect(res.status).toBe(200);
    const html = await res.text();
    expect(html).toContain('<!DOCTYPE html>');
  });

  it('GET / supports agents=hide filter', async () => {
    db.upsertSession(mockSession);
    const res = await app.request('/?agents=hide');
    expect(res.status).toBe(200);
    expect(await res.text()).toContain('<!DOCTYPE html>');
  });

  it('GET /search returns search page HTML', async () => {
    db.upsertSession(mockSession);
    const res = await app.request('/search');
    expect(res.status).toBe(200);
    const html = await res.text();
    expect(html).toContain('<!DOCTYPE html>');
  });

  it('GET /stats returns stats page HTML', async () => {
    db.upsertSession(mockSession);
    const res = await app.request('/stats');
    expect(res.status).toBe(200);
    const html = await res.text();
    expect(html).toContain('<!DOCTYPE html>');
  });

  it('GET /stats supports group_by parameter', async () => {
    db.upsertSession(mockSession);
    const res = await app.request('/stats?group_by=project');
    expect(res.status).toBe(200);
    expect(await res.text()).toContain('<!DOCTYPE html>');
  });

  it('GET /settings returns settings page HTML', async () => {
    const res = await app.request('/settings');
    expect(res.status).toBe(200);
    const html = await res.text();
    expect(html).toContain('<!DOCTYPE html>');
  });

  it('GET /health returns health dashboard HTML', async () => {
    db.upsertSession(mockSession);
    const res = await app.request('/health');
    expect(res.status).toBe(200);
    const html = await res.text();
    expect(html).toContain('<!DOCTYPE html>');
  });

  it('GET /session/:id returns 404 HTML for missing session', async () => {
    const res = await app.request('/session/nonexistent');
    expect(res.status).toBe(404);
    const html = await res.text();
    expect(html).toContain('Not Found');
  });

  it('GET /session/:id returns session detail HTML', async () => {
    db.upsertSession(mockSession);
    const res = await app.request('/session/session-001');
    expect(res.status).toBe(200);
    const html = await res.text();
    expect(html).toContain('<!DOCTYPE html>');
  });
});
