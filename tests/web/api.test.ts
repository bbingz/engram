import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import type { SessionAdapter, SessionInfo } from '../../src/adapters/types.js';
import { Database } from '../../src/core/db.js';
import type { LogWriter } from '../../src/core/logger.js';
import { createApp } from '../../src/web.js';

const mockSession: SessionInfo = {
  id: 'api-test-session-001',
  source: 'codex',
  startTime: '2026-01-01T10:00:00.000Z',
  endTime: '2026-01-01T11:00:00.000Z',
  cwd: '/Users/test/project',
  project: 'my-project',
  model: 'gpt-4o',
  messageCount: 20,
  userMessageCount: 10,
  assistantMessageCount: 8,
  toolMessageCount: 2,
  systemMessageCount: 0,
  summary: 'Fix login bug',
  filePath: '/Users/test/.codex/sessions/rollout-123.jsonl',
  sizeBytes: 50000,
};

describe('Web API', () => {
  let db: Database;
  let app: ReturnType<typeof createApp>;

  beforeEach(() => {
    db = new Database(':memory:');
    app = createApp(db);
  });

  afterEach(() => {
    db.close();
  });

  // 1. GET /health returns 200
  it('GET /health returns 200', async () => {
    const res = await app.request('/health');
    expect(res.status).toBe(200);
  });

  // 2. POST /api/log with valid body → 200
  it('POST /api/log with valid body returns 200', async () => {
    const res = await app.request('/api/log', {
      method: 'POST',
      body: JSON.stringify({
        level: 'info',
        module: 'test',
        message: 'hello world',
      }),
      headers: { 'Content-Type': 'application/json' },
    });
    expect(res.status).toBe(200);
    const body = await res.json();
    expect(body.ok).toBe(true);
  });

  // 3. POST /api/log with invalid level → 400
  it('POST /api/log with invalid level returns 400', async () => {
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
    const body = await res.json();
    expect(body.ok).toBe(false);
  });

  // 4. POST /api/log with malformed JSON → 400
  it('POST /api/log with malformed JSON returns 400', async () => {
    const res = await app.request('/api/log', {
      method: 'POST',
      body: '{not valid json',
      headers: { 'Content-Type': 'application/json' },
    });
    expect(res.status).toBe(400);
    const body = await res.json();
    expect(body.ok).toBe(false);
  });

  // 5. POST /api/log with missing fields → 400
  it('POST /api/log with missing fields returns 400', async () => {
    const res = await app.request('/api/log', {
      method: 'POST',
      body: JSON.stringify({ level: 'info' }),
      headers: { 'Content-Type': 'application/json' },
    });
    expect(res.status).toBe(400);
    const body = await res.json();
    expect(body.ok).toBe(false);
  });

  // 6. OPTIONS preflight → returns 204 for localhost origin (CORS accepted)
  it('OPTIONS preflight returns 204 for localhost origin', async () => {
    const res = await app.request('/api/sessions', {
      method: 'OPTIONS',
      headers: { Origin: 'http://localhost:3457' },
    });
    // CORS preflight should return 204 (not rejected)
    expect(res.status).toBe(204);
  });

  // 6b. CORS rejects non-localhost origin
  it('CORS rejects non-localhost origin', async () => {
    const res = await app.request('/api/sessions', {
      method: 'GET',
      headers: { Origin: 'https://evil.example.com' },
    });
    expect(res.status).toBe(403);
  });

  // 7. GET /api/sessions → returns list
  it('GET /api/sessions returns session list', async () => {
    db.upsertSession(mockSession);
    const res = await app.request('/api/sessions');
    expect(res.status).toBe(200);
    const body = await res.json();
    expect(body.sessions).toBeDefined();
    expect(Array.isArray(body.sessions)).toBe(true);
  });

  it('GET /api/sessions/:id/messages returns paginated rendered messages', async () => {
    db.upsertSession(mockSession);
    const messages = Array.from({ length: 5 }, (_, i) => ({
      role: i % 2 === 0 ? ('user' as const) : ('assistant' as const),
      content: `message ${i + 1}`,
    }));
    const adapter: SessionAdapter = {
      name: 'codex',
      detect: async () => true,
      listSessionFiles: async function* () {},
      parseSessionInfo: async () => null,
      streamMessages: async function* (_filePath, opts = {}) {
        const offset = opts.offset ?? 0;
        const limit = opts.limit ?? messages.length;
        for (const message of messages.slice(offset, offset + limit)) {
          yield message;
        }
      },
      isAccessible: async () => true,
    };
    const appWithAdapter = createApp(db, { adapters: [adapter] });

    const res = await appWithAdapter.request(
      '/api/sessions/api-test-session-001/messages?offset=2&limit=2',
    );
    expect(res.status).toBe(200);
    const body = await res.json();
    expect(body.offset).toBe(2);
    expect(body.limit).toBe(2);
    expect(body.count).toBe(2);
    expect(body.hasMore).toBe(true);
    expect(body.nextOffset).toBe(4);
    expect(body.html).toContain('message 3');
    expect(body.html).toContain('message 4');
    expect(body.html).not.toContain('message 5');
  });

  it('GET /api/sessions/:id/messages filters tool messages like the Swift detail view', async () => {
    db.upsertSession(mockSession);
    const messages = [
      { role: 'user' as const, content: 'Review the Antigravity CLI parser' },
      { role: 'tool' as const, content: 'raw tool output should stay hidden' },
      { role: 'assistant' as const, content: 'The parser is aligned.' },
    ];
    const adapter: SessionAdapter = {
      name: 'codex',
      detect: async () => true,
      listSessionFiles: async function* () {},
      parseSessionInfo: async () => null,
      streamMessages: async function* () {
        for (const message of messages) yield message;
      },
      isAccessible: async () => true,
    };
    const appWithAdapter = createApp(db, { adapters: [adapter] });

    const res = await appWithAdapter.request(
      '/api/sessions/api-test-session-001/messages',
    );

    expect(res.status).toBe(200);
    const body = await res.json();
    expect(body.count).toBe(2);
    expect(body.html).toContain('Review the Antigravity CLI parser');
    expect(body.html).toContain('The parser is aligned.');
    expect(body.html).not.toContain('raw tool output should stay hidden');
  });

  it('GET /api/sessions/:id/messages paginates after filtering hidden tool messages', async () => {
    db.upsertSession(mockSession);
    const messages = [
      { role: 'user' as const, content: 'visible 1' },
      { role: 'tool' as const, content: 'hidden tool 1' },
      {
        role: 'user' as const,
        content: '# AGENTS.md instructions for /tmp\nhidden system',
      },
      { role: 'user' as const, content: '   ' },
      {
        role: 'user' as const,
        content: '<command-name>hidden agent comm</command-name>',
      },
      { role: 'tool' as const, content: 'hidden tool 2' },
      { role: 'assistant' as const, content: 'visible 2' },
      { role: 'user' as const, content: 'visible 3' },
    ];
    const adapter: SessionAdapter = {
      name: 'codex',
      detect: async () => true,
      listSessionFiles: async function* () {},
      parseSessionInfo: async () => null,
      streamMessages: async function* () {
        for (const message of messages) yield message;
      },
      isAccessible: async () => true,
    };
    const appWithAdapter = createApp(db, { adapters: [adapter] });

    const res = await appWithAdapter.request(
      '/api/sessions/api-test-session-001/messages?offset=0&limit=2',
    );

    expect(res.status).toBe(200);
    const body = await res.json();
    expect(body.count).toBe(2);
    expect(body.hasMore).toBe(true);
    expect(body.nextOffset).toBe(7);
    expect(body.html).toContain('visible 1');
    expect(body.html).toContain('visible 2');
    expect(body.html).not.toContain('visible 3');
    expect(body.html).not.toContain('hidden tool');
    expect(body.html).not.toContain('hidden system');
    expect(body.html).not.toContain('hidden agent comm');

    const nextRes = await appWithAdapter.request(
      `/api/sessions/api-test-session-001/messages?offset=${body.nextOffset}&limit=2`,
    );
    const nextBody = await nextRes.json();
    expect(nextBody.hasMore).toBe(false);
    expect(nextBody.nextOffset).toBe(8);
    expect(nextBody.html).toContain('visible 3');
    expect(nextBody.html).not.toContain('visible 1');
  });

  it('GET /session/:id renders only the first transcript page', async () => {
    db.upsertSession({
      ...mockSession,
      id: 'paged-session',
      messageCount: 60,
      userMessageCount: 30,
      assistantMessageCount: 30,
    });
    const messages = Array.from({ length: 60 }, (_, i) => ({
      role: i % 2 === 0 ? ('user' as const) : ('assistant' as const),
      content: `transcript message ${i + 1}`,
    }));
    const adapter: SessionAdapter = {
      name: 'codex',
      detect: async () => true,
      listSessionFiles: async function* () {},
      parseSessionInfo: async () => null,
      streamMessages: async function* (_filePath, opts = {}) {
        const offset = opts.offset ?? 0;
        const limit = opts.limit ?? messages.length;
        for (const message of messages.slice(offset, offset + limit)) {
          yield message;
        }
      },
      isAccessible: async () => true,
    };
    const appWithAdapter = createApp(db, { adapters: [adapter] });

    const res = await appWithAdapter.request('/session/paged-session');
    expect(res.status).toBe(200);
    const html = await res.text();
    expect(html).toContain('transcript message 1');
    expect(html).toContain('transcript message 50');
    expect(html).not.toContain('transcript message 51');
    expect(html).toContain('Load more');
  });

  // 8. GET /api/sessions/:id → 404 for nonexistent
  it('GET /api/sessions/:id returns 404 for nonexistent session', async () => {
    const res = await app.request('/api/sessions/does-not-exist-xyz');
    expect(res.status).toBe(404);
  });

  // 9. X-Trace-Id header propagated in response
  it('X-Trace-Id header propagated in response', async () => {
    const traceId = 'test-trace-abc-123';
    const res = await app.request('/api/sessions', {
      headers: { 'X-Trace-Id': traceId },
    });
    expect(res.headers.get('X-Trace-Id')).toBe(traceId);
  });

  // 10. Unknown route → 404
  it('unknown route returns 404', async () => {
    const res = await app.request('/api/this-route-does-not-exist-ever');
    expect(res.status).toBe(404);
  });

  // R5-2: /api/link-sessions confines targetDir to $HOME like other write
  // endpoints. A path outside $HOME must be rejected before any FS work.
  it('POST /api/link-sessions rejects targetDir outside $HOME', async () => {
    const res = await app.request('/api/link-sessions', {
      method: 'POST',
      body: JSON.stringify({ targetDir: '/etc/evil-symlinks' }),
      headers: { 'Content-Type': 'application/json' },
    });
    expect(res.status).toBe(400);
    const body = await res.json();
    expect(body.error).toMatch(/must live under/);
  });
});

// R5-40: /api/log bounds the free-form `data` blob.
describe('Web API — /api/log data cap', () => {
  let db: Database;
  let captured: Array<{ data?: unknown }>;

  beforeEach(() => {
    db = new Database(':memory:');
    captured = [];
  });

  afterEach(() => {
    db.close();
  });

  it('replaces oversized data with a truncation marker', async () => {
    const app = createApp(db, {
      // Minimal capturing stub of LogWriter; only write() is exercised here.
      logWriter: {
        write: (entry: { data?: unknown }) => captured.push(entry),
      } as unknown as LogWriter,
    });
    const big = 'z'.repeat(100 * 1024); // > 64KB cap
    const res = await app.request('/api/log', {
      method: 'POST',
      body: JSON.stringify({
        level: 'info',
        module: 'test',
        message: 'oversized',
        data: { blob: big },
      }),
      headers: { 'Content-Type': 'application/json' },
    });
    expect(res.status).toBe(200);
    expect(captured).toHaveLength(1);
    expect(captured[0].data).toEqual({
      _truncated: true,
      reason: 'data exceeded 64KB limit',
    });
  });

  it('passes through small data unchanged', async () => {
    const app = createApp(db, {
      // Minimal capturing stub of LogWriter; only write() is exercised here.
      logWriter: {
        write: (entry: { data?: unknown }) => captured.push(entry),
      } as unknown as LogWriter,
    });
    const res = await app.request('/api/log', {
      method: 'POST',
      body: JSON.stringify({
        level: 'info',
        module: 'test',
        message: 'ok',
        data: { k: 'v' },
      }),
      headers: { 'Content-Type': 'application/json' },
    });
    expect(res.status).toBe(200);
    expect(captured[0].data).toEqual({ k: 'v' });
  });
});

describe('Web API — bearer token auth', () => {
  let db: Database;
  let protectedApp: ReturnType<typeof createApp>;

  beforeEach(() => {
    db = new Database(':memory:');
    protectedApp = createApp(db, {
      settings: { httpBearerToken: 'test-secret' },
    });
  });

  afterEach(() => {
    db.close();
  });

  // 11. POST /api/log without token → 401
  it('POST /api/log without bearer token returns 401', async () => {
    const res = await protectedApp.request('/api/log', {
      method: 'POST',
      body: JSON.stringify({ level: 'info', module: 'test', message: 'hello' }),
      headers: { 'Content-Type': 'application/json' },
    });
    expect(res.status).toBe(401);
  });

  // 12. POST /api/log with wrong token → 401
  it('POST /api/log with wrong bearer token returns 401', async () => {
    const res = await protectedApp.request('/api/log', {
      method: 'POST',
      body: JSON.stringify({ level: 'info', module: 'test', message: 'hello' }),
      headers: {
        'Content-Type': 'application/json',
        Authorization: 'Bearer wrong-token',
      },
    });
    expect(res.status).toBe(401);
  });
});
