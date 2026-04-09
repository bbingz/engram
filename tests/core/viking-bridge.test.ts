// tests/core/viking-bridge.test.ts
import { afterEach, describe, expect, it, vi } from 'vitest';
import {
  sessionIdFromVikingUri,
  toVikingUri,
  VikingBridge,
} from '../../src/core/viking-bridge.js';

describe('URI helpers', () => {
  it('toVikingUri builds correct URI', () => {
    expect(toVikingUri('claude-code', 'engram', 'abc-123')).toBe(
      'viking://session/claude-code/engram/abc-123',
    );
    expect(toVikingUri('codex', undefined, 'x')).toBe(
      'viking://session/codex/unknown/x',
    );
  });
  it('sessionIdFromVikingUri extracts session ID', () => {
    expect(
      sessionIdFromVikingUri('viking://session/claude-code/engram/abc-123'),
    ).toBe('abc-123');
    expect(sessionIdFromVikingUri('invalid')).toBe('');
  });
});

describe('VikingBridge', () => {
  it('creates instance with url and apiKey', () => {
    const bridge = new VikingBridge('http://localhost:1933', 'test-key');
    expect(bridge).toBeInstanceOf(VikingBridge);
  });
});

describe('isAvailable', () => {
  afterEach(() => vi.unstubAllGlobals());

  it('returns true when server responds with auth header', async () => {
    const bridge = new VikingBridge('http://localhost:1933', 'key');
    const mockFetch = vi.fn().mockResolvedValue({ ok: true });
    vi.stubGlobal('fetch', mockFetch);
    const result = await bridge.isAvailable();
    expect(result).toBe(true);
    expect(mockFetch).toHaveBeenCalledWith(
      'http://localhost:1933/api/v1/debug/health',
      expect.objectContaining({
        method: 'GET',
        headers: expect.objectContaining({ Authorization: 'Bearer key' }),
      }),
    );
  });

  it('returns false when server is unreachable', async () => {
    const bridge = new VikingBridge('http://localhost:1933', 'key');
    vi.stubGlobal(
      'fetch',
      vi.fn().mockRejectedValue(new Error('ECONNREFUSED')),
    );
    expect(await bridge.isAvailable()).toBe(false);
  });
});

describe('checkAvailable (circuit breaker)', () => {
  afterEach(() => vi.unstubAllGlobals());

  it('caches results and skips network call within TTL', async () => {
    const bridge = new VikingBridge('http://localhost:1933', 'key');
    const mockFetch = vi.fn().mockRejectedValue(new Error('down'));
    vi.stubGlobal('fetch', mockFetch);
    expect(await bridge.checkAvailable()).toBe(false);
    expect(mockFetch).toHaveBeenCalledTimes(1);
    expect(await bridge.checkAvailable()).toBe(false);
    expect(mockFetch).toHaveBeenCalledTimes(1); // cached
  });

  it('circuit breaker recovers after TTL expires', async () => {
    const bridge = new VikingBridge('http://localhost:1933', 'key');

    // First call: server is down → opens circuit breaker
    const mockFetch = vi.fn().mockRejectedValue(new Error('ECONNREFUSED'));
    vi.stubGlobal('fetch', mockFetch);
    expect(await bridge.checkAvailable()).toBe(false);
    expect(mockFetch).toHaveBeenCalledTimes(1);

    // Within TTL: cached result, no new network call
    expect(await bridge.checkAvailable()).toBe(false);
    expect(mockFetch).toHaveBeenCalledTimes(1);

    // Expire the TTL by backdating lastHealthCheck
    (bridge as unknown as { lastHealthCheck: number }).lastHealthCheck = 0;

    // Server is now up → circuit breaker closes and returns true
    mockFetch.mockResolvedValue({ ok: true });
    expect(await bridge.checkAvailable()).toBe(true);
    expect(mockFetch).toHaveBeenCalledTimes(2);

    // Verify breaker state is closed (circuitOpen = false)
    expect((bridge as unknown as { circuitOpen: boolean }).circuitOpen).toBe(
      false,
    );
  });
});

describe('addResource', () => {
  afterEach(() => vi.unstubAllGlobals());

  it('uploads temp file then imports as resource', async () => {
    const bridge = new VikingBridge('http://localhost:1933', 'key');
    const mockFetch = vi
      .fn()
      .mockResolvedValueOnce({
        ok: true,
        json: () =>
          Promise.resolve({ result: { temp_path: '/tmp/upload_abc.md' } }),
      })
      .mockResolvedValueOnce({
        ok: true,
        json: () => Promise.resolve({ status: 'ok' }),
      });
    vi.stubGlobal('fetch', mockFetch);
    await bridge.addResource(
      'viking://session/claude-code/engram/001',
      'session content',
      {},
    );
    expect(mockFetch).toHaveBeenCalledTimes(2);
    expect(mockFetch.mock.calls[0][0]).toBe(
      'http://localhost:1933/api/v1/resources/temp_upload',
    );
    expect(mockFetch.mock.calls[1][0]).toBe(
      'http://localhost:1933/api/v1/resources',
    );
    const importBody = JSON.parse(mockFetch.mock.calls[1][1].body);
    expect(importBody.preserve_structure).toBe(true);
  });

  it('throws on temp_upload error', async () => {
    const bridge = new VikingBridge('http://localhost:1933', 'key');
    vi.stubGlobal(
      'fetch',
      vi.fn().mockResolvedValue({
        ok: false,
        status: 500,
        text: () => Promise.resolve('err'),
      }),
    );
    await expect(bridge.addResource('p', 'c')).rejects.toThrow(
      'Viking temp_upload failed',
    );
  });
});

describe('find', () => {
  afterEach(() => vi.unstubAllGlobals());

  it('includes skills in find results', async () => {
    const bridge = new VikingBridge('http://localhost:1933', 'key');
    vi.stubGlobal(
      'fetch',
      vi.fn().mockResolvedValue({
        ok: true,
        json: () =>
          Promise.resolve({
            result: {
              resources: [
                {
                  uri: 'viking://resource/a',
                  score: 0.9,
                  abstract: 'Resource A',
                },
              ],
              memories: [
                { uri: 'viking://memory/b', score: 0.8, abstract: 'Memory B' },
              ],
              skills: [
                { uri: 'viking://skill/c', score: 0.7, abstract: 'Skill C' },
              ],
            },
          }),
      }),
    );
    const results = await bridge.find('test query');
    expect(results).toHaveLength(3);
    expect(results.map((r) => r.uri)).toContain('viking://skill/c');
  });

  it('returns semantic search results (POST /find)', async () => {
    const bridge = new VikingBridge('http://localhost:1933', 'key');
    vi.stubGlobal(
      'fetch',
      vi.fn().mockResolvedValue({
        ok: true,
        json: () =>
          Promise.resolve({
            result: {
              resources: [
                { uri: 'viking://session/a', score: 0.95, abstract: 'SSL fix' },
              ],
              memories: [],
            },
          }),
      }),
    );
    const results = await bridge.find('SSL error');
    expect(results).toHaveLength(1);
    expect(results[0].uri).toBe('viking://session/a');
    expect(results[0].score).toBe(0.95);
  });

  it('returns empty array on error', async () => {
    const bridge = new VikingBridge('http://localhost:1933', 'key');
    vi.stubGlobal('fetch', vi.fn().mockRejectedValue(new Error('timeout')));
    expect(await bridge.find('query')).toEqual([]);
  });
});

describe('grep', () => {
  afterEach(() => vi.unstubAllGlobals());

  it('returns keyword search results (POST /grep)', async () => {
    const bridge = new VikingBridge('http://localhost:1933', 'key');
    vi.stubGlobal(
      'fetch',
      vi.fn().mockResolvedValue({
        ok: true,
        json: () =>
          Promise.resolve({
            result: [{ uri: 'u', score: 1, snippet: 'match' }],
          }),
      }),
    );
    expect(await bridge.grep('SSL')).toHaveLength(1);
  });
});

describe('tiered read', () => {
  afterEach(() => vi.unstubAllGlobals());

  it('abstract returns L0 via GET /abstract', async () => {
    const bridge = new VikingBridge('http://localhost:1933', 'key');
    vi.stubGlobal(
      'fetch',
      vi.fn().mockResolvedValue({
        ok: true,
        json: () => Promise.resolve({ result: 'Brief summary' }),
      }),
    );
    expect(await bridge.abstract('viking://session/a')).toBe('Brief summary');
  });

  it('overview returns L1 via GET /overview', async () => {
    const bridge = new VikingBridge('http://localhost:1933', 'key');
    vi.stubGlobal(
      'fetch',
      vi.fn().mockResolvedValue({
        ok: true,
        json: () => Promise.resolve({ result: 'Detailed overview...' }),
      }),
    );
    expect(await bridge.overview('viking://session/a')).toBe(
      'Detailed overview...',
    );
  });

  it('returns empty string on error', async () => {
    const bridge = new VikingBridge('http://localhost:1933', 'key');
    vi.stubGlobal('fetch', vi.fn().mockRejectedValue(new Error('fail')));
    expect(await bridge.abstract('viking://session/a')).toBe('');
  });
});

describe('ls', () => {
  afterEach(() => vi.unstubAllGlobals());

  it('lists entries via GET /ls', async () => {
    const bridge = new VikingBridge('http://localhost:1933', 'key');
    const entries = [{ uri: 'viking://session/a/b', type: 'session' }];
    vi.stubGlobal(
      'fetch',
      vi.fn().mockResolvedValue({
        ok: true,
        json: () => Promise.resolve({ result: entries }),
      }),
    );
    expect(await bridge.ls('viking://session/a')).toEqual(entries);
  });
});

describe('agentId header', () => {
  afterEach(() => vi.unstubAllGlobals());

  it('includes X-Agent-Id header when agentId is provided', async () => {
    const bridge = new VikingBridge('http://localhost:1933', 'key', {
      agentId: 'ffb1327b18bf',
    });
    const mockFetch = vi.fn().mockResolvedValue({ ok: true });
    vi.stubGlobal('fetch', mockFetch);
    await bridge.isAvailable();
    const headers = mockFetch.mock.calls[0][1].headers;
    expect(headers['X-Agent-Id']).toBe('ffb1327b18bf');
  });

  it('omits X-Agent-Id header when agentId is not provided', async () => {
    const bridge = new VikingBridge('http://localhost:1933', 'key');
    const mockFetch = vi.fn().mockResolvedValue({ ok: true });
    vi.stubGlobal('fetch', mockFetch);
    await bridge.isAvailable();
    const headers = mockFetch.mock.calls[0][1].headers;
    expect(headers).not.toHaveProperty('X-Agent-Id');
  });
});

describe('memory', () => {
  afterEach(() => vi.unstubAllGlobals());

  it('extractMemory sends content via addResource (resources flow)', async () => {
    const bridge = new VikingBridge('http://localhost:1933', 'key');
    const mockFetch = vi
      .fn()
      .mockResolvedValueOnce({
        ok: true,
        json: () => Promise.resolve({ result: { temp_path: '/tmp/m.md' } }),
      })
      .mockResolvedValueOnce({
        ok: true,
        json: () => Promise.resolve({ status: 'ok' }),
      });
    vi.stubGlobal('fetch', mockFetch);
    await bridge.extractMemory('session content');
    expect(mockFetch.mock.calls[0][0]).toBe(
      'http://localhost:1933/api/v1/resources/temp_upload',
    );
  });

  it('findMemories searches both user and agent memory scopes', async () => {
    const bridge = new VikingBridge('http://localhost:1933', 'key');
    const mockFetch = vi
      .fn()
      // First find call (user memories)
      .mockResolvedValueOnce({
        ok: true,
        json: () =>
          Promise.resolve({
            result: {
              memories: [
                {
                  uri: 'viking://user/style',
                  score: 0.9,
                  abstract: 'User prefers TypeScript',
                  metadata: { createdAt: '2026-03-16' },
                },
              ],
              resources: [],
            },
          }),
      })
      // Second find call (agent memories)
      .mockResolvedValueOnce({
        ok: true,
        json: () =>
          Promise.resolve({
            result: {
              memories: [
                {
                  uri: 'viking://agent/pattern',
                  score: 0.7,
                  abstract: 'Agent learned TDD',
                  metadata: { createdAt: '2026-03-15' },
                },
              ],
              resources: [],
            },
          }),
      });
    vi.stubGlobal('fetch', mockFetch);
    const result = await bridge.findMemories('coding style');

    // Should return both results sorted by confidence descending
    expect(result).toHaveLength(2);
    expect(result[0].confidence).toBe(0.9);
    expect(result[0].content).toBe('User prefers TypeScript');
    expect(result[1].confidence).toBe(0.7);
    expect(result[1].content).toBe('Agent learned TDD');

    // Verify two separate find calls with correct target_uri
    expect(mockFetch).toHaveBeenCalledTimes(2);
    const call1Body = JSON.parse(mockFetch.mock.calls[0][1].body);
    const call2Body = JSON.parse(mockFetch.mock.calls[1][1].body);
    expect(call1Body.target_uri).toBe('viking://user/');
    expect(call2Body.target_uri).toBe('viking://agent/');
  });

  it('findMemories returns empty array on error', async () => {
    const bridge = new VikingBridge('http://localhost:1933', 'key');
    vi.stubGlobal('fetch', vi.fn().mockRejectedValue(new Error('fail')));
    expect(await bridge.findMemories('query')).toEqual([]);
  });
});

describe('pushSession', () => {
  afterEach(() => vi.unstubAllGlobals());

  it('creates session, adds messages serially, then commits', async () => {
    const bridge = new VikingBridge('http://localhost:1933', 'key');
    const mockFetch = vi.fn().mockResolvedValue({
      ok: true,
      json: () => Promise.resolve({ status: 'ok', result: {} }),
    });
    vi.stubGlobal('fetch', mockFetch);

    await bridge.pushSession('engram-claude-code-myproject-abc123', [
      { role: 'user', content: 'Fix the bug' },
      { role: 'assistant', content: 'Found the issue...' },
    ]);

    // 1 create + 2 messages + 1 commit = 4 calls
    expect(mockFetch).toHaveBeenCalledTimes(4);
    expect(mockFetch.mock.calls[0][0]).toBe(
      'http://localhost:1933/api/v1/sessions/custom',
    );
    expect(JSON.parse(mockFetch.mock.calls[0][1].body).session_id).toBe(
      'engram-claude-code-myproject-abc123',
    );
    // Messages in order
    expect(mockFetch.mock.calls[1][0]).toMatch(/\/messages$/);
    expect(JSON.parse(mockFetch.mock.calls[1][1].body).role).toBe('user');
    expect(mockFetch.mock.calls[2][0]).toMatch(/\/messages$/);
    expect(JSON.parse(mockFetch.mock.calls[2][1].body).role).toBe('assistant');
    // Commit
    expect(mockFetch.mock.calls[3][0]).toContain('/commit/async');
  });

  it('sends messages with parts format (not flat content)', async () => {
    const bridge = new VikingBridge('http://localhost:1933', 'key');
    const mockFetch = vi.fn().mockResolvedValue({
      ok: true,
      json: () => Promise.resolve({ status: 'ok', result: {} }),
    });
    vi.stubGlobal('fetch', mockFetch);

    await bridge.pushSession('test-parts', [
      { role: 'user', content: 'Hello world' },
    ]);

    // Message call is the 2nd fetch call (after session create)
    const messageBody = JSON.parse(mockFetch.mock.calls[1][1].body);
    expect(messageBody.parts).toEqual([{ type: 'text', text: 'Hello world' }]);
    expect(messageBody).not.toHaveProperty('content');
  });

  it('throws on session creation failure with descriptive error', async () => {
    const bridge = new VikingBridge('http://localhost:1933', 'key');
    vi.stubGlobal(
      'fetch',
      vi.fn().mockResolvedValue({
        ok: false,
        status: 400,
        text: () => Promise.resolve('Bad request'),
      }),
    );
    await expect(
      bridge.pushSession('id', [{ role: 'user', content: 'hi' }]),
    ).rejects.toThrow(/sessions\/custom.*400/);
  });
});

describe('post retry logic', () => {
  afterEach(() => vi.unstubAllGlobals());

  it('retries on 429 and succeeds', async () => {
    vi.useFakeTimers();
    const bridge = new VikingBridge('http://localhost:1933', 'key');
    const mockFetch = vi
      .fn()
      .mockResolvedValueOnce({
        ok: false,
        status: 429,
        text: () => Promise.resolve('rate limited'),
        headers: new Map(),
      })
      .mockResolvedValueOnce({
        ok: true,
        json: () => Promise.resolve({ status: 'ok', result: {} }),
      })
      .mockResolvedValueOnce({
        ok: true,
        json: () => Promise.resolve({ status: 'ok', result: {} }),
      });
    vi.stubGlobal('fetch', mockFetch);
    const p = bridge.pushSession('test-retry', []);
    await vi.advanceTimersByTimeAsync(30_000);
    await p;
    expect(mockFetch).toHaveBeenCalledTimes(3); // retry create + succeed + commit
    vi.useRealTimers();
  });

  it('retries on 500 and succeeds', async () => {
    vi.useFakeTimers();
    const bridge = new VikingBridge('http://localhost:1933', 'key');
    const mockFetch = vi
      .fn()
      .mockResolvedValueOnce({
        ok: false,
        status: 500,
        text: () => Promise.resolve('error'),
      })
      .mockResolvedValueOnce({
        ok: true,
        json: () => Promise.resolve({ status: 'ok', result: {} }),
      })
      .mockResolvedValueOnce({
        ok: true,
        json: () => Promise.resolve({ status: 'ok', result: {} }),
      });
    vi.stubGlobal('fetch', mockFetch);
    const p = bridge.pushSession('test-retry-500', []);
    await vi.advanceTimersByTimeAsync(30_000);
    await p;
    expect(mockFetch).toHaveBeenCalledTimes(3);
    vi.useRealTimers();
  });

  it('throws after 3 retries on persistent 429', async () => {
    vi.useFakeTimers();
    const bridge = new VikingBridge('http://localhost:1933', 'key');
    vi.stubGlobal(
      'fetch',
      vi.fn().mockResolvedValue({
        ok: false,
        status: 429,
        text: () => Promise.resolve('rate limited'),
        headers: new Map(),
      }),
    );
    // Catch immediately to prevent unhandled rejection during timer advance
    const p = bridge.pushSession('test-exhaust', []).catch((e: Error) => e);
    await vi.advanceTimersByTimeAsync(60_000);
    const err = await p;
    expect(err).toBeInstanceOf(Error);
    expect((err as Error).message).toMatch(/rate limited after 3 retries/);
    vi.useRealTimers();
  });

  it('does NOT retry on 400 client error', async () => {
    const bridge = new VikingBridge('http://localhost:1933', 'key');
    const mockFetch = vi.fn().mockResolvedValue({
      ok: false,
      status: 400,
      text: () => Promise.resolve('bad request'),
    });
    vi.stubGlobal('fetch', mockFetch);
    await expect(bridge.pushSession('test-no-retry', [])).rejects.toThrow(
      /400/,
    );
    expect(mockFetch).toHaveBeenCalledTimes(1);
  });

  it('exhausts all retries on persistent 500 and throws', async () => {
    vi.useFakeTimers();
    const bridge = new VikingBridge('http://localhost:1933', 'key');
    const mockFetch = vi.fn().mockResolvedValue({
      ok: false,
      status: 500,
      text: () => Promise.resolve('internal server error'),
    });
    vi.stubGlobal('fetch', mockFetch);
    const p = bridge.pushSession('test-exhaust-500', []).catch((e: Error) => e);
    await vi.advanceTimersByTimeAsync(30_000);
    const err = await p;
    expect(err).toBeInstanceOf(Error);
    expect((err as Error).message).toMatch(/500/);
    expect(mockFetch).toHaveBeenCalledTimes(3);
    vi.useRealTimers();
  });

  it('handles network error on push gracefully (throws, does not hang)', async () => {
    const bridge = new VikingBridge('http://localhost:1933', 'key');
    // Simulate a fetch that rejects (connection refused / socket hang up)
    const mockFetch = vi.fn().mockRejectedValue(new Error('socket hang up'));
    vi.stubGlobal('fetch', mockFetch);
    await expect(bridge.pushSession('test-network-error', [])).rejects.toThrow(
      'socket hang up',
    );
    // Network errors are not retried by the post() helper (they throw immediately)
    expect(mockFetch).toHaveBeenCalledTimes(1);
  });
});

describe('deleteResources', () => {
  afterEach(() => vi.unstubAllGlobals());

  it('sends DELETE to /fs with recursive flag', async () => {
    const bridge = new VikingBridge('http://localhost:1933', 'key');
    const mockFetch = vi.fn().mockResolvedValue({ ok: true });
    vi.stubGlobal('fetch', mockFetch);
    await bridge.deleteResources();
    const url = mockFetch.mock.calls[0][0] as string;
    expect(url).toContain('/api/v1/fs');
    expect(url).toContain('recursive=true');
    expect(mockFetch.mock.calls[0][1].method).toBe('DELETE');
  });

  it('throws on delete failure', async () => {
    const bridge = new VikingBridge('http://localhost:1933', 'key');
    vi.stubGlobal(
      'fetch',
      vi.fn().mockResolvedValue({
        ok: false,
        status: 500,
        text: () => Promise.resolve('delete failed'),
      }),
    );
    await expect(bridge.deleteResources()).rejects.toThrow(
      /deleteResources.*500/,
    );
  });
});

describe('audit integration', () => {
  afterEach(() => vi.unstubAllGlobals());

  it('records audit entry for find()', async () => {
    const audit = { record: vi.fn().mockReturnValue(1) };
    const bridge = new VikingBridge('http://localhost:1933', 'key', {
      audit: audit as any,
    });
    vi.stubGlobal(
      'fetch',
      vi.fn().mockResolvedValue({
        ok: true,
        status: 200,
        json: () =>
          Promise.resolve({ status: 'ok', result: { resources: [] } }),
      }),
    );
    await bridge.find('test query');
    expect(audit.record).toHaveBeenCalledWith(
      expect.objectContaining({
        caller: 'viking',
        operation: 'find',
        provider: 'viking',
        method: 'POST',
        statusCode: 200,
      }),
    );
  });

  it('records audit entry for pushSession as summary', async () => {
    const audit = { record: vi.fn().mockReturnValue(1) };
    const bridge = new VikingBridge('http://localhost:1933', 'key', {
      audit: audit as any,
    });
    vi.stubGlobal(
      'fetch',
      vi.fn().mockResolvedValue({
        ok: true,
        json: () => Promise.resolve({ status: 'ok', result: {} }),
      }),
    );
    await bridge.pushSession('test-id', [
      { role: 'user', content: 'hi' },
      { role: 'assistant', content: 'hello' },
    ]);
    // Should only record ONE audit entry (summary), not per-message
    const pushCalls = audit.record.mock.calls.filter(
      (c: any) => c[0].operation === 'pushSession',
    );
    expect(pushCalls).toHaveLength(1);
    expect(pushCalls[0][0].sessionId).toBe('test-id');
    expect(pushCalls[0][0].meta.messageCount).toBe(2);
  });

  it('does not record per-message audit in pushSession', async () => {
    const audit = { record: vi.fn().mockReturnValue(1) };
    const bridge = new VikingBridge('http://localhost:1933', 'key', {
      audit: audit as any,
    });
    vi.stubGlobal(
      'fetch',
      vi.fn().mockResolvedValue({
        ok: true,
        json: () => Promise.resolve({ status: 'ok', result: {} }),
      }),
    );
    await bridge.pushSession('test-id', [
      { role: 'user', content: 'msg1' },
      { role: 'assistant', content: 'msg2' },
      { role: 'user', content: 'msg3' },
    ]);
    // Only 1 audit call total (the summary), not 1 per message + create + commit
    expect(audit.record).toHaveBeenCalledTimes(1);
    expect(audit.record.mock.calls[0][0].operation).toBe('pushSession');
    expect(audit.record.mock.calls[0][0].meta.messageCount).toBe(3);
  });

  it('records audit with error on find failure', async () => {
    const audit = { record: vi.fn().mockReturnValue(1) };
    const bridge = new VikingBridge('http://localhost:1933', 'key', {
      audit: audit as any,
    });
    vi.stubGlobal(
      'fetch',
      vi.fn().mockRejectedValue(new Error('network error')),
    );
    await bridge.find('query');
    expect(audit.record).toHaveBeenCalledWith(
      expect.objectContaining({
        caller: 'viking',
        operation: 'find',
        error: 'network error',
      }),
    );
  });

  it('records audit with error on pushSession failure', async () => {
    const audit = { record: vi.fn().mockReturnValue(1) };
    const bridge = new VikingBridge('http://localhost:1933', 'key', {
      audit: audit as any,
    });
    vi.stubGlobal(
      'fetch',
      vi.fn().mockRejectedValue(new Error('connection refused')),
    );
    await expect(
      bridge.pushSession('id', [{ role: 'user', content: 'hi' }]),
    ).rejects.toThrow('connection refused');
    expect(audit.record).toHaveBeenCalledWith(
      expect.objectContaining({
        caller: 'viking',
        operation: 'pushSession',
        error: 'connection refused',
        sessionId: 'id',
      }),
    );
  });

  it('records audit for isAvailable()', async () => {
    const audit = { record: vi.fn().mockReturnValue(1) };
    const bridge = new VikingBridge('http://localhost:1933', 'key', {
      audit: audit as any,
    });
    vi.stubGlobal(
      'fetch',
      vi.fn().mockResolvedValue({ ok: true, status: 200 }),
    );
    await bridge.isAvailable();
    expect(audit.record).toHaveBeenCalledWith(
      expect.objectContaining({
        caller: 'viking',
        operation: 'isAvailable',
        method: 'GET',
      }),
    );
  });

  it('records audit for grep()', async () => {
    const audit = { record: vi.fn().mockReturnValue(1) };
    const bridge = new VikingBridge('http://localhost:1933', 'key', {
      audit: audit as any,
    });
    vi.stubGlobal(
      'fetch',
      vi.fn().mockResolvedValue({
        ok: true,
        status: 200,
        json: () => Promise.resolve({ result: [] }),
      }),
    );
    await bridge.grep('pattern');
    expect(audit.record).toHaveBeenCalledWith(
      expect.objectContaining({
        caller: 'viking',
        operation: 'grep',
        method: 'POST',
      }),
    );
  });

  it('records audit for ls()', async () => {
    const audit = { record: vi.fn().mockReturnValue(1) };
    const bridge = new VikingBridge('http://localhost:1933', 'key', {
      audit: audit as any,
    });
    vi.stubGlobal(
      'fetch',
      vi.fn().mockResolvedValue({
        ok: true,
        status: 200,
        json: () => Promise.resolve({ result: [] }),
      }),
    );
    await bridge.ls('viking://session/a');
    expect(audit.record).toHaveBeenCalledWith(
      expect.objectContaining({
        caller: 'viking',
        operation: 'ls',
        method: 'GET',
      }),
    );
  });
});

describe('observer proxy', () => {
  afterEach(() => vi.unstubAllGlobals());

  it('observerSystem returns parsed result', async () => {
    const bridge = new VikingBridge('http://localhost:1933', 'key');
    vi.stubGlobal(
      'fetch',
      vi.fn().mockResolvedValue({
        ok: true,
        json: () =>
          Promise.resolve({ result: { uptime: 12345, version: '1.0' } }),
      }),
    );
    const data = await bridge.observerSystem();
    expect(data).toEqual({ uptime: 12345, version: '1.0' });
  });

  it('observerQueue returns null on error', async () => {
    const bridge = new VikingBridge('http://localhost:1933', 'key');
    vi.stubGlobal('fetch', vi.fn().mockRejectedValue(new Error('timeout')));
    expect(await bridge.observerQueue()).toBeNull();
  });

  it('observerVlm returns null on non-ok response', async () => {
    const bridge = new VikingBridge('http://localhost:1933', 'key');
    vi.stubGlobal(
      'fetch',
      vi.fn().mockResolvedValue({ ok: false, status: 500 }),
    );
    expect(await bridge.observerVlm()).toBeNull();
  });

  it('observerVikingdb calls correct endpoint', async () => {
    const bridge = new VikingBridge('http://localhost:1933', 'key');
    const mockFetch = vi.fn().mockResolvedValue({
      ok: true,
      json: () => Promise.resolve({ result: { tables: 5 } }),
    });
    vi.stubGlobal('fetch', mockFetch);
    await bridge.observerVikingdb();
    expect(mockFetch.mock.calls[0][0]).toBe(
      'http://localhost:1933/api/v1/observer/vikingdb',
    );
  });

  it('observerTransaction calls correct endpoint', async () => {
    const bridge = new VikingBridge('http://localhost:1933', 'key');
    const mockFetch = vi.fn().mockResolvedValue({
      ok: true,
      json: () => Promise.resolve({ result: { active: 0 } }),
    });
    vi.stubGlobal('fetch', mockFetch);
    await bridge.observerTransaction();
    expect(mockFetch.mock.calls[0][0]).toBe(
      'http://localhost:1933/api/v1/observer/transaction',
    );
  });
});
