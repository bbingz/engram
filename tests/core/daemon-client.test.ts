import { describe, expect, it } from 'vitest';
import {
  DaemonClient,
  DaemonClientError,
  shouldFallbackToDirect,
} from '../../src/core/daemon-client.js';

function makeFetch(
  responder: (
    url: string,
    init: RequestInit,
  ) => {
    status: number;
    body: string;
    ok?: boolean;
  },
): typeof fetch {
  return (async (input: RequestInfo | URL, init?: RequestInit) => {
    const url = input instanceof URL ? input.toString() : String(input);
    const r = responder(url, init ?? {});
    const ok = r.ok ?? (r.status >= 200 && r.status < 300);
    return new Response(r.body, {
      status: r.status,
      statusText: ok ? 'OK' : 'ERR',
    });
  }) as typeof fetch;
}

describe('DaemonClient.post', () => {
  it('sends JSON with bearer token and parses JSON response', async () => {
    let seen: { url: string; init: RequestInit } | undefined;
    const fetchImpl = makeFetch((url, init) => {
      seen = { url, init };
      return { status: 200, body: JSON.stringify({ id: 'abc', ok: true }) };
    });
    const client = new DaemonClient({
      baseUrl: 'http://127.0.0.1:3457/',
      bearerToken: 'tok',
      fetchImpl,
    });

    const result = await client.post<{ id: string; ok: boolean }>('/api/x', {
      a: 1,
    });
    expect(result).toEqual({ id: 'abc', ok: true });
    expect(seen?.url).toBe('http://127.0.0.1:3457/api/x');
    expect(seen?.init.method).toBe('POST');
    expect(JSON.parse(String(seen?.init.body))).toEqual({ a: 1 });
    expect((seen?.init.headers as Record<string, string>).authorization).toBe(
      'Bearer tok',
    );
    expect((seen?.init.headers as Record<string, string>)['content-type']).toBe(
      'application/json',
    );
  });

  it('omits Authorization header when no token given', async () => {
    let seenHeaders: Record<string, string> | undefined;
    const fetchImpl = makeFetch((_url, init) => {
      seenHeaders = init.headers as Record<string, string>;
      return { status: 200, body: '{}' };
    });
    const client = new DaemonClient({ baseUrl: 'http://x', fetchImpl });
    await client.post('/p', {});
    expect(seenHeaders?.authorization).toBeUndefined();
  });

  it('throws DaemonClientError with status + body for HTTP errors', async () => {
    const fetchImpl = makeFetch(() => ({
      status: 400,
      body: JSON.stringify({ error: 'bad input' }),
    }));
    const client = new DaemonClient({ baseUrl: 'http://x', fetchImpl });
    await expect(client.post('/p', {})).rejects.toMatchObject({
      name: 'DaemonClientError',
      status: 400,
    });
    try {
      await client.post('/p', {});
    } catch (err) {
      expect(err).toBeInstanceOf(DaemonClientError);
      expect((err as DaemonClientError).body).toEqual({ error: 'bad input' });
      expect((err as Error).message).toContain('bad input');
    }
  });

  it('returns undefined for empty body', async () => {
    const fetchImpl = makeFetch(() => ({ status: 200, body: '' }));
    const client = new DaemonClient({ baseUrl: 'http://x', fetchImpl });
    const r = await client.post('/p', {});
    expect(r).toBeUndefined();
  });

  it('aborts when the timeout expires', async () => {
    const fetchImpl = ((_input: RequestInfo | URL, init?: RequestInit) =>
      new Promise((_resolve, reject) => {
        init?.signal?.addEventListener('abort', () => {
          reject(new DOMException('aborted', 'AbortError'));
        });
      })) as typeof fetch;
    const client = new DaemonClient({
      baseUrl: 'http://x',
      fetchImpl,
      timeoutMs: 20,
    });
    await expect(client.post('/p', {})).rejects.toMatchObject({
      name: 'AbortError',
    });
  });

  it('handles non-JSON response bodies gracefully', async () => {
    const fetchImpl = makeFetch(() => ({ status: 200, body: 'plain text' }));
    const client = new DaemonClient({ baseUrl: 'http://x', fetchImpl });
    const r = await client.post<string>('/p', {});
    expect(r).toBe('plain text');
  });
});

describe('shouldFallbackToDirect', () => {
  it('falls back on non-DaemonClientError (network / abort)', () => {
    expect(shouldFallbackToDirect(new Error('ECONNREFUSED'), false)).toBe(true);
    expect(
      shouldFallbackToDirect(new DOMException('abort', 'AbortError'), false),
    ).toBe(true);
  });

  it('falls back on 404 / 405 / 501 without structured body (missing endpoint)', () => {
    const mk = (s: number) =>
      new DaemonClientError(s, 'Not Found', `HTTP ${s}`);
    expect(shouldFallbackToDirect(mk(404), false)).toBe(true);
    expect(shouldFallbackToDirect(mk(405), false)).toBe(true);
    expect(shouldFallbackToDirect(mk(501), false)).toBe(true);
  });

  it('bubbles 404 / 405 WITH envelope (application-level rejection)', () => {
    const err = new DaemonClientError(
      404,
      { error: 'Session not found: abc' },
      'HTTP 404',
    );
    expect(shouldFallbackToDirect(err, false)).toBe(false);
  });

  it('bubbles 404 with a non-{error} JSON body (e.g. {message:...})', () => {
    // Round 1 hotfix: any JSON-object body on a 404/405/501 means the
    // endpoint is present and answered — bubble up the rejection instead
    // of silently falling back to a direct write.
    const err = new DaemonClientError(
      404,
      { message: 'migration id does not exist', code: 'MIGRATION_NOT_FOUND' },
      'HTTP 404',
    );
    expect(shouldFallbackToDirect(err, false)).toBe(false);
  });

  it('bubbles 404 with empty JSON-object body (still structured)', () => {
    const err = new DaemonClientError(404, {}, 'HTTP 404');
    expect(shouldFallbackToDirect(err, false)).toBe(false);
  });

  it('falls back on 404 with a string body (Hono default route-not-found)', () => {
    const err = new DaemonClientError(404, '404 Not Found', 'HTTP 404');
    expect(shouldFallbackToDirect(err, false)).toBe(true);
  });

  it('bubbles 4xx validation rejections (400 / 409 / 422)', () => {
    const mk = (s: number) =>
      new DaemonClientError(s, { error: 'bad' }, `HTTP ${s}`);
    expect(shouldFallbackToDirect(mk(400), false)).toBe(false);
    expect(shouldFallbackToDirect(mk(409), false)).toBe(false);
    expect(shouldFallbackToDirect(mk(422), false)).toBe(false);
  });

  it('falls back on 5xx server errors', () => {
    const err = new DaemonClientError(500, { error: 'internal' }, 'HTTP 500');
    expect(shouldFallbackToDirect(err, false)).toBe(true);
  });

  it('never falls back when strict mode is on', () => {
    expect(shouldFallbackToDirect(new Error('net'), true)).toBe(false);
    expect(
      shouldFallbackToDirect(
        new DaemonClientError(404, 'missing', 'HTTP 404'),
        true,
      ),
    ).toBe(false);
    expect(
      shouldFallbackToDirect(
        new DaemonClientError(500, { error: 'boom' }, 'HTTP 500'),
        true,
      ),
    ).toBe(false);
  });
});

describe('DaemonClient.delete', () => {
  it('sends DELETE without a body + without content-type', async () => {
    let seen: { init: RequestInit } | undefined;
    const fetchImpl = makeFetch((_url, init) => {
      seen = { init };
      return { status: 200, body: JSON.stringify({ ok: true }) };
    });
    const client = new DaemonClient({ baseUrl: 'http://x', fetchImpl });
    await client.delete('/api/x/1');
    expect(seen?.init.method).toBe('DELETE');
    expect(seen?.init.body).toBeUndefined();
    expect(
      (seen?.init.headers as Record<string, string>)['content-type'],
    ).toBeUndefined();
  });

  it('supports DELETE with a JSON body (needed for /api/project-aliases)', async () => {
    let seen: { init: RequestInit } | undefined;
    const fetchImpl = makeFetch((_url, init) => {
      seen = { init };
      return { status: 200, body: JSON.stringify({ ok: true }) };
    });
    const client = new DaemonClient({ baseUrl: 'http://x', fetchImpl });
    await client.delete('/api/project-aliases', {
      alias: 'a',
      canonical: 'b',
    });
    expect(seen?.init.method).toBe('DELETE');
    expect(JSON.parse(String(seen?.init.body))).toEqual({
      alias: 'a',
      canonical: 'b',
    });
    expect((seen?.init.headers as Record<string, string>)['content-type']).toBe(
      'application/json',
    );
  });
});
