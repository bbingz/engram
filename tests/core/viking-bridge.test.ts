// tests/core/viking-bridge.test.ts
import { describe, it, expect, vi, afterEach } from 'vitest';
import { VikingBridge, sessionIdFromVikingUri, toVikingUri } from '../../src/core/viking-bridge.js';

describe('URI helpers', () => {
  it('toVikingUri builds correct URI', () => {
    expect(toVikingUri('claude-code', 'engram', 'abc-123')).toBe('viking://session/claude-code/engram/abc-123');
    expect(toVikingUri('codex', undefined, 'x')).toBe('viking://session/codex/unknown/x');
  });
  it('sessionIdFromVikingUri extracts session ID', () => {
    expect(sessionIdFromVikingUri('viking://session/claude-code/engram/abc-123')).toBe('abc-123');
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
      })
    );
  });

  it('returns false when server is unreachable', async () => {
    const bridge = new VikingBridge('http://localhost:1933', 'key');
    vi.stubGlobal('fetch', vi.fn().mockRejectedValue(new Error('ECONNREFUSED')));
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
});

describe('addResource', () => {
  afterEach(() => vi.unstubAllGlobals());

  it('uploads temp file then imports as resource', async () => {
    const bridge = new VikingBridge('http://localhost:1933', 'key');
    const mockFetch = vi.fn()
      .mockResolvedValueOnce({ ok: true, json: () => Promise.resolve({ result: { temp_path: '/tmp/upload_abc.md' } }) })
      .mockResolvedValueOnce({ ok: true, json: () => Promise.resolve({ status: 'ok' }) });
    vi.stubGlobal('fetch', mockFetch);
    await bridge.addResource('viking://session/claude-code/engram/001', 'session content', {});
    expect(mockFetch).toHaveBeenCalledTimes(2);
    expect(mockFetch.mock.calls[0][0]).toBe('http://localhost:1933/api/v1/resources/temp_upload');
    expect(mockFetch.mock.calls[1][0]).toBe('http://localhost:1933/api/v1/resources');
    const importBody = JSON.parse(mockFetch.mock.calls[1][1].body);
    expect(importBody.preserve_structure).toBe(true);
  });

  it('throws on temp_upload error', async () => {
    const bridge = new VikingBridge('http://localhost:1933', 'key');
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue({ ok: false, status: 500, text: () => Promise.resolve('err') }));
    await expect(bridge.addResource('p', 'c')).rejects.toThrow('Viking temp_upload failed');
  });
});

describe('find', () => {
  afterEach(() => vi.unstubAllGlobals());

  it('returns semantic search results (POST /find)', async () => {
    const bridge = new VikingBridge('http://localhost:1933', 'key');
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue({
      ok: true, json: () => Promise.resolve({ result: {
        resources: [{ uri: 'viking://session/a', score: 0.95, abstract: 'SSL fix' }],
        memories: [],
      }}),
    }));
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
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue({
      ok: true, json: () => Promise.resolve({ result: [{ uri: 'u', score: 1, snippet: 'match' }] }),
    }));
    expect(await bridge.grep('SSL')).toHaveLength(1);
  });
});

describe('tiered read', () => {
  afterEach(() => vi.unstubAllGlobals());

  it('abstract returns L0 via GET /abstract', async () => {
    const bridge = new VikingBridge('http://localhost:1933', 'key');
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue({
      ok: true, json: () => Promise.resolve({ result: 'Brief summary' }),
    }));
    expect(await bridge.abstract('viking://session/a')).toBe('Brief summary');
  });

  it('overview returns L1 via GET /overview', async () => {
    const bridge = new VikingBridge('http://localhost:1933', 'key');
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue({
      ok: true, json: () => Promise.resolve({ result: 'Detailed overview...' }),
    }));
    expect(await bridge.overview('viking://session/a')).toBe('Detailed overview...');
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
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue({
      ok: true, json: () => Promise.resolve({ result: entries }),
    }));
    expect(await bridge.ls('viking://session/a')).toEqual(entries);
  });
});

describe('memory', () => {
  afterEach(() => vi.unstubAllGlobals());

  it('extractMemory sends content via addResource (resources flow)', async () => {
    const bridge = new VikingBridge('http://localhost:1933', 'key');
    const mockFetch = vi.fn()
      .mockResolvedValueOnce({ ok: true, json: () => Promise.resolve({ result: { temp_path: '/tmp/m.md' } }) })
      .mockResolvedValueOnce({ ok: true, json: () => Promise.resolve({ status: 'ok' }) });
    vi.stubGlobal('fetch', mockFetch);
    await bridge.extractMemory('session content');
    expect(mockFetch.mock.calls[0][0]).toBe('http://localhost:1933/api/v1/resources/temp_upload');
  });

  it('findMemories uses find with memory URI prefix', async () => {
    const bridge = new VikingBridge('http://localhost:1933', 'key');
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue({
      ok: true, json: () => Promise.resolve({ result: {
        memories: [{ uri: 'viking://memory/style', score: 0.9, abstract: 'User prefers TypeScript', metadata: { createdAt: '2026-03-16' } }],
        resources: [],
      }}),
    }));
    const result = await bridge.findMemories('coding style');
    expect(result).toHaveLength(1);
    expect(result[0].content).toBe('User prefers TypeScript');
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
      ok: true, json: () => Promise.resolve({ status: 'ok', result: {} }),
    });
    vi.stubGlobal('fetch', mockFetch);

    await bridge.pushSession('engram-claude-code-myproject-abc123', [
      { role: 'user', content: 'Fix the bug' },
      { role: 'assistant', content: 'Found the issue...' },
    ]);

    // 1 create + 2 messages + 1 commit = 4 calls
    expect(mockFetch).toHaveBeenCalledTimes(4);
    expect(mockFetch.mock.calls[0][0]).toBe('http://localhost:1933/api/v1/sessions/custom');
    expect(JSON.parse(mockFetch.mock.calls[0][1].body).session_id).toBe('engram-claude-code-myproject-abc123');
    // Messages in order
    expect(mockFetch.mock.calls[1][0]).toContain('/messages/async');
    expect(JSON.parse(mockFetch.mock.calls[1][1].body).role).toBe('user');
    expect(mockFetch.mock.calls[2][0]).toContain('/messages/async');
    expect(JSON.parse(mockFetch.mock.calls[2][1].body).role).toBe('assistant');
    // Commit
    expect(mockFetch.mock.calls[3][0]).toContain('/commit/async');
  });

  it('throws on session creation failure with descriptive error', async () => {
    const bridge = new VikingBridge('http://localhost:1933', 'key');
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue({
      ok: false, status: 400, text: () => Promise.resolve('Bad request'),
    }));
    await expect(bridge.pushSession('id', [{ role: 'user', content: 'hi' }]))
      .rejects.toThrow(/sessions\/custom.*400/);
  });
});

describe('post retry logic', () => {
  afterEach(() => vi.unstubAllGlobals());

  it('retries on 429 and succeeds', async () => {
    const bridge = new VikingBridge('http://localhost:1933', 'key');
    const mockFetch = vi.fn()
      .mockResolvedValueOnce({ ok: false, status: 429, text: () => Promise.resolve('rate limited') })
      .mockResolvedValueOnce({ ok: true, json: () => Promise.resolve({ status: 'ok', result: {} }) })
      .mockResolvedValueOnce({ ok: true, json: () => Promise.resolve({ status: 'ok', result: {} }) });
    vi.stubGlobal('fetch', mockFetch);
    await bridge.pushSession('test-retry', []);
    expect(mockFetch).toHaveBeenCalledTimes(3); // retry create + succeed + commit
  });

  it('retries on 500 and succeeds', async () => {
    const bridge = new VikingBridge('http://localhost:1933', 'key');
    const mockFetch = vi.fn()
      .mockResolvedValueOnce({ ok: false, status: 500, text: () => Promise.resolve('error') })
      .mockResolvedValueOnce({ ok: true, json: () => Promise.resolve({ status: 'ok', result: {} }) })
      .mockResolvedValueOnce({ ok: true, json: () => Promise.resolve({ status: 'ok', result: {} }) });
    vi.stubGlobal('fetch', mockFetch);
    await bridge.pushSession('test-retry-500', []);
    expect(mockFetch).toHaveBeenCalledTimes(3);
  });

  it('throws after 3 retries on persistent 429', async () => {
    const bridge = new VikingBridge('http://localhost:1933', 'key');
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue({
      ok: false, status: 429, text: () => Promise.resolve('rate limited'),
    }));
    await expect(bridge.pushSession('test-exhaust', []))
      .rejects.toThrow(/after 3 retries/);
  });

  it('does NOT retry on 400 client error', async () => {
    const bridge = new VikingBridge('http://localhost:1933', 'key');
    const mockFetch = vi.fn().mockResolvedValue({
      ok: false, status: 400, text: () => Promise.resolve('bad request'),
    });
    vi.stubGlobal('fetch', mockFetch);
    await expect(bridge.pushSession('test-no-retry', []))
      .rejects.toThrow(/400/);
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
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue({
      ok: false, status: 500, text: () => Promise.resolve('delete failed'),
    }));
    await expect(bridge.deleteResources()).rejects.toThrow(/deleteResources.*500/);
  });
});
