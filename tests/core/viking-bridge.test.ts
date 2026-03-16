// tests/core/viking-bridge.test.ts
import { describe, it, expect, vi, afterEach } from 'vitest';
import { VikingBridge, sessionIdFromVikingUri } from '../../src/core/viking-bridge.js';

describe('sessionIdFromVikingUri', () => {
  it('extracts session ID from valid URI', () => {
    expect(sessionIdFromVikingUri('viking://sessions/claude-code/engram/abc-123')).toBe('abc-123');
  });
  it('returns empty string for invalid URI', () => {
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
      'http://localhost:1933/api/health',
      expect.objectContaining({
        method: 'GET',
        signal: expect.any(AbortSignal),
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

  it('caches false result and skips network call within TTL', async () => {
    const bridge = new VikingBridge('http://localhost:1933', 'key');
    const mockFetch = vi.fn().mockRejectedValue(new Error('down'));
    vi.stubGlobal('fetch', mockFetch);
    expect(await bridge.checkAvailable()).toBe(false);
    expect(mockFetch).toHaveBeenCalledTimes(1);
    expect(await bridge.checkAvailable()).toBe(false);
    expect(mockFetch).toHaveBeenCalledTimes(1); // no additional call
  });
});

describe('addResource', () => {
  afterEach(() => vi.unstubAllGlobals());

  it('sends content to OpenViking', async () => {
    const bridge = new VikingBridge('http://localhost:1933', 'key');
    const mockFetch = vi.fn().mockResolvedValue({ ok: true });
    vi.stubGlobal('fetch', mockFetch);
    await bridge.addResource('viking://sessions/claude-code/engram/001', 'session content', {
      source: 'claude-code', project: 'engram',
    });
    expect(mockFetch).toHaveBeenCalledWith(
      'http://localhost:1933/api/resources',
      expect.objectContaining({
        method: 'POST',
        body: JSON.stringify({
          uri: 'viking://sessions/claude-code/engram/001',
          content: 'session content',
          metadata: { source: 'claude-code', project: 'engram' },
        }),
      })
    );
  });

  it('throws on server error', async () => {
    const bridge = new VikingBridge('http://localhost:1933', 'key');
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue({ ok: false, status: 500, text: () => Promise.resolve('Internal error') }));
    await expect(bridge.addResource('uri', 'content')).rejects.toThrow('Viking addResource failed');
  });
});

describe('find', () => {
  afterEach(() => vi.unstubAllGlobals());

  it('returns semantic search results', async () => {
    const bridge = new VikingBridge('http://localhost:1933', 'key');
    const mockResults = [{ uri: 'viking://sessions/a', score: 0.95, snippet: 'SSL error fix' }];
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue({
      ok: true, json: () => Promise.resolve({ results: mockResults }),
    }));
    expect(await bridge.find('SSL error')).toEqual(mockResults);
  });

  it('returns empty array on error', async () => {
    const bridge = new VikingBridge('http://localhost:1933', 'key');
    vi.stubGlobal('fetch', vi.fn().mockRejectedValue(new Error('timeout')));
    expect(await bridge.find('query')).toEqual([]);
  });
});

describe('grep', () => {
  afterEach(() => vi.unstubAllGlobals());

  it('returns keyword search results', async () => {
    const bridge = new VikingBridge('http://localhost:1933', 'key');
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue({
      ok: true, json: () => Promise.resolve({ results: [{ uri: 'u', score: 1, snippet: 'match' }] }),
    }));
    expect(await bridge.grep('SSL')).toHaveLength(1);
  });
});

describe('tiered read', () => {
  afterEach(() => vi.unstubAllGlobals());

  it('abstract returns L0 summary', async () => {
    const bridge = new VikingBridge('http://localhost:1933', 'key');
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue({
      ok: true, json: () => Promise.resolve({ content: 'Brief summary' }),
    }));
    expect(await bridge.abstract('viking://sessions/a')).toBe('Brief summary');
  });

  it('overview returns L1 summary', async () => {
    const bridge = new VikingBridge('http://localhost:1933', 'key');
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue({
      ok: true, json: () => Promise.resolve({ content: 'Detailed overview...' }),
    }));
    expect(await bridge.overview('viking://sessions/a')).toBe('Detailed overview...');
  });

  it('returns empty string on error', async () => {
    const bridge = new VikingBridge('http://localhost:1933', 'key');
    vi.stubGlobal('fetch', vi.fn().mockRejectedValue(new Error('fail')));
    expect(await bridge.abstract('viking://sessions/a')).toBe('');
  });
});

describe('ls', () => {
  afterEach(() => vi.unstubAllGlobals());

  it('lists entries under a URI', async () => {
    const bridge = new VikingBridge('http://localhost:1933', 'key');
    const entries = [{ uri: 'viking://sessions/a/b', type: 'session' }];
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue({
      ok: true, json: () => Promise.resolve({ entries }),
    }));
    expect(await bridge.ls('viking://sessions/a')).toEqual(entries);
  });
});

describe('memory', () => {
  afterEach(() => vi.unstubAllGlobals());

  it('extractMemory sends content', async () => {
    const bridge = new VikingBridge('http://localhost:1933', 'key');
    const mockFetch = vi.fn().mockResolvedValue({ ok: true });
    vi.stubGlobal('fetch', mockFetch);
    await bridge.extractMemory('session content');
    expect(mockFetch).toHaveBeenCalledWith(
      'http://localhost:1933/api/memory/extract',
      expect.objectContaining({ method: 'POST' })
    );
  });

  it('findMemories returns results', async () => {
    const bridge = new VikingBridge('http://localhost:1933', 'key');
    const memories = [{ content: 'User prefers TypeScript', source: 'session-1', confidence: 0.9, createdAt: '2026-03-16' }];
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue({
      ok: true, json: () => Promise.resolve({ memories }),
    }));
    expect(await bridge.findMemories('coding style')).toEqual(memories);
  });

  it('findMemories returns empty array on error', async () => {
    const bridge = new VikingBridge('http://localhost:1933', 'key');
    vi.stubGlobal('fetch', vi.fn().mockRejectedValue(new Error('fail')));
    expect(await bridge.findMemories('query')).toEqual([]);
  });
});
