// Contract tests: DaemonClient routing decisions match what the endpoints
// actually return. Guards against drift between the helper's "envelope-ness"
// detection and Hono's real 404 shape, and between MCP dispatch expectations
// and the current endpoint responses.

import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import {
  DaemonClient,
  DaemonClientError,
  shouldFallbackToDirect,
} from '../../src/core/daemon-client.js';
import { Database } from '../../src/core/db.js';
import { createApp } from '../../src/web.js';

function proxyFetch(app: ReturnType<typeof createApp>): typeof fetch {
  return ((input: RequestInfo | URL, init?: RequestInit) => {
    const url =
      input instanceof URL
        ? input.pathname + input.search
        : String(input).replace(/^http:\/\/[^/]+/, '');
    return app.request(url, init);
  }) as typeof fetch;
}

describe('DaemonClient → /api/summary (Phase B Step 2 contract)', () => {
  let db: Database;
  let app: ReturnType<typeof createApp>;
  let client: DaemonClient;

  beforeEach(() => {
    db = new Database(':memory:');
    app = createApp(db);
    client = new DaemonClient({
      baseUrl: 'http://127.0.0.1:3457',
      fetchImpl: proxyFetch(app),
    });
  });

  afterEach(() => {
    db.close();
  });

  it('404 for missing session carries a structured envelope → MCP should NOT fall back', async () => {
    let caught: unknown;
    try {
      await client.post('/api/summary', { sessionId: 'does-not-exist' });
    } catch (err) {
      caught = err;
    }
    expect(caught).toBeInstanceOf(DaemonClientError);
    const err = caught as DaemonClientError;
    expect(err.status).toBe(404);
    expect(err.body).toMatchObject({
      error: expect.stringMatching(/not found/i),
    });
    // Core contract: with envelope → bubble up to caller, not fallback.
    expect(shouldFallbackToDirect(err, false)).toBe(false);
  });

  it('400 for missing sessionId bubbles up as validation error', async () => {
    let caught: unknown;
    try {
      await client.post('/api/summary', {});
    } catch (err) {
      caught = err;
    }
    expect(caught).toBeInstanceOf(DaemonClientError);
    expect((caught as DaemonClientError).status).toBe(400);
    expect(shouldFallbackToDirect(caught, false)).toBe(false);
  });

  it('unreachable daemon → transport error, falls back to direct', async () => {
    const unreachable = new DaemonClient({
      baseUrl: 'http://127.0.0.1:1', // port 1 is nothing
      timeoutMs: 150,
      fetchImpl: (async () => {
        throw new TypeError('fetch failed');
      }) as typeof fetch,
    });
    let caught: unknown;
    try {
      await unreachable.post('/api/summary', { sessionId: 'x' });
    } catch (err) {
      caught = err;
    }
    expect(caught).toBeInstanceOf(TypeError);
    expect(shouldFallbackToDirect(caught, false)).toBe(true);
  });
});

describe('DaemonClient → /api/project-aliases (Phase B Step 4 contract)', () => {
  let db: Database;
  let app: ReturnType<typeof createApp>;
  let client: DaemonClient;

  beforeEach(() => {
    db = new Database(':memory:');
    app = createApp(db);
    client = new DaemonClient({
      baseUrl: 'http://127.0.0.1:3457',
      fetchImpl: proxyFetch(app),
    });
  });

  afterEach(() => {
    db.close();
  });

  it('POST adds alias and DELETE removes it via DaemonClient round-trip', async () => {
    const added = await client.post<{
      added: { alias: string; canonical: string };
    }>('/api/project-aliases', { alias: 'foo', canonical: 'bar' });
    expect(added.added).toEqual({ alias: 'foo', canonical: 'bar' });
    expect(db.listProjectAliases()).toContainEqual({
      alias: 'foo',
      canonical: 'bar',
    });

    const removed = await client.delete<{
      removed: { alias: string; canonical: string };
    }>('/api/project-aliases', { alias: 'foo', canonical: 'bar' });
    expect(removed.removed).toEqual({ alias: 'foo', canonical: 'bar' });
    expect(db.listProjectAliases()).toEqual([]);
  });

  it('400 with {error} envelope bubbles up (does not fall back)', async () => {
    let caught: unknown;
    try {
      await client.post('/api/project-aliases', { alias: 'only-alias' });
    } catch (err) {
      caught = err;
    }
    expect(caught).toBeInstanceOf(DaemonClientError);
    expect((caught as DaemonClientError).status).toBe(400);
    expect(shouldFallbackToDirect(caught, false)).toBe(false);
  });
});
