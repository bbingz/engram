import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { DaemonClient } from '../../src/core/daemon-client.js';
import { Database } from '../../src/core/db.js';
import { createApp } from '../../src/web.js';

describe('POST /api/insight', () => {
  let db: Database;
  let app: ReturnType<typeof createApp>;

  beforeEach(() => {
    db = new Database(':memory:');
    app = createApp(db);
  });

  afterEach(() => {
    db.close();
  });

  async function post(body: unknown) {
    return app.request('/api/insight', {
      method: 'POST',
      body: JSON.stringify(body),
      headers: { 'Content-Type': 'application/json' },
    });
  }

  it('saves a valid insight and persists it to the text store', async () => {
    const res = await post({
      content: 'Never mix vectors from different embedding models.',
      wing: 'engram',
      room: 'vector-store',
      importance: 4,
    });
    expect(res.status).toBe(200);
    const payload = (await res.json()) as {
      id: string;
      content: string;
      wing?: string;
      importance: number;
    };
    expect(payload.id).toMatch(/^[0-9a-f-]{36}$/);
    expect(payload.wing).toBe('engram');

    const row = db.raw
      .prepare('SELECT id, content, wing, importance FROM insights WHERE id=?')
      .get(payload.id) as {
      id: string;
      content: string;
      wing: string;
      importance: number;
    };
    expect(row.content).toMatch(/different embedding/);
    expect(row.wing).toBe('engram');
    expect(row.importance).toBe(4);
  });

  it('returns 400 envelope when content is missing', async () => {
    const res = await post({ wing: 'x' });
    expect(res.status).toBe(400);
    const body = (await res.json()) as {
      error: { name: string; message: string; retry_policy: string };
    };
    expect(body.error.name).toBe('MissingParam');
    expect(body.error.retry_policy).toBe('never');
    expect(body.error.message).toMatch(/content/i);
  });

  it('returns 400 envelope when content is too short', async () => {
    const res = await post({ content: 'hi' });
    expect(res.status).toBe(400);
    const body = (await res.json()) as {
      error: { name: string; message: string; retry_policy: string };
    };
    expect(body.error.name).toBe('InvalidInsight');
    expect(body.error.retry_policy).toBe('never');
    expect(body.error.message).toMatch(/too short/i);
  });

  it('concurrent identical saves collapse to a single row (regression)', async () => {
    // 6-way review asked whether concurrent save_insight calls could race
    // past the dedup check and produce duplicates. Analysis: the text-only
    // path has no await between findDuplicateInsight and saveInsightText,
    // and better-sqlite3 is synchronous — Node's single-thread invariant
    // serializes the two handlers end-to-end. This test pins that property:
    // two Promise.all'd posts with identical content must produce exactly
    // one row, the second response carrying a duplicateWarning.
    const payload = {
      content: 'Phase B single-writer rules out concurrent DB writers.',
      wing: 'concurrency',
    };
    const [res1, res2] = await Promise.all([post(payload), post(payload)]);
    const [a, b] = (await Promise.all([res1.json(), res2.json()])) as Array<{
      id: string;
      duplicateWarning?: string;
    }>;
    const warnings = [a.duplicateWarning, b.duplicateWarning].filter(Boolean);
    expect(warnings).toHaveLength(1);
    expect(a.id).toBe(b.id);
    const rows = db.raw
      .prepare('SELECT COUNT(*) AS n FROM insights WHERE wing = ?')
      .get('concurrency') as { n: number };
    expect(rows.n).toBe(1);
  });

  it('dedups against an existing identical insight', async () => {
    const first = await post({
      content: 'SQLite busy_timeout must be at least 30s under contention.',
    });
    const a = (await first.json()) as { id: string };

    const second = await post({
      content: 'SQLite busy_timeout must be at least 30s under contention.',
    });
    expect(second.status).toBe(200);
    const b = (await second.json()) as {
      id: string;
      duplicateWarning?: string;
    };
    expect(b.id).toBe(a.id);
    expect(b.duplicateWarning).toBeDefined();
  });
});

// Phase B contract: DaemonClient over the real Hono app produces the same DB
// state as calling the endpoint directly. Uses a fetch-shim that routes through
// app.request() instead of a real network listener.
describe('DaemonClient → /api/insight (contract)', () => {
  let db: Database;
  let app: ReturnType<typeof createApp>;
  let client: DaemonClient;

  beforeEach(() => {
    db = new Database(':memory:');
    app = createApp(db);
    const fetchImpl = ((input: RequestInfo | URL, init?: RequestInit) => {
      const url =
        input instanceof URL
          ? input.pathname + input.search
          : String(input).replace(/^http:\/\/[^/]+/, '');
      return app.request(url, init);
    }) as typeof fetch;
    client = new DaemonClient({ baseUrl: 'http://127.0.0.1:3457', fetchImpl });
  });

  afterEach(() => {
    db.close();
  });

  it('round-trips a save through HTTP and persists to DB', async () => {
    const result = await client.post<{ id: string; content: string }>(
      '/api/insight',
      {
        content: 'Daemon is the only writer in Phase B architecture.',
        wing: 'engram',
        importance: 3,
      },
    );
    expect(result.id).toMatch(/^[0-9a-f-]{36}$/);
    const row = db.raw
      .prepare('SELECT content, wing, importance FROM insights WHERE id=?')
      .get(result.id) as {
      content: string;
      wing: string;
      importance: number;
    };
    expect(row.content).toMatch(/only writer/);
    expect(row.importance).toBe(3);
  });

  it('surfaces 400 validation errors as DaemonClientError', async () => {
    await expect(
      client.post('/api/insight', { content: 'short' }),
    ).rejects.toMatchObject({ name: 'DaemonClientError', status: 400 });
  });
});
