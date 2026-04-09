import { afterEach, describe, expect, it, vi } from 'vitest';
import type { AiAuditWriter } from '../../src/core/ai-audit.js';
import {
  createEmbeddingClient,
  type EmbeddingClient,
} from '../../src/core/embeddings.js';

describe('EmbeddingClient', () => {
  it('returns null when no provider is available', async () => {
    const client = createEmbeddingClient({
      ollamaUrl: 'http://localhost:99999',
      openaiApiKey: undefined,
    });
    const result = await client.embed('test text');
    expect(result).toBeNull();
  });

  it('returns Float32Array of correct dimension when mocked', async () => {
    const mockClient: EmbeddingClient = {
      embed: async () => new Float32Array(768).fill(0.1),
      dimension: 768,
      model: 'mock',
    };
    const result = await mockClient.embed('hello world');
    expect(result).toBeInstanceOf(Float32Array);
    expect(result?.length).toBe(768);
  });
});

describe('EmbeddingClient audit', () => {
  function makeAudit() {
    return {
      record: vi.fn().mockReturnValue(1),
    } as unknown as AiAuditWriter & { record: ReturnType<typeof vi.fn> };
  }

  afterEach(() => {
    vi.unstubAllGlobals();
  });

  it('Ollama success records audit with prompt_eval_count', async () => {
    const audit = makeAudit();
    vi.stubGlobal(
      'fetch',
      vi.fn().mockResolvedValue({
        ok: true,
        json: () =>
          Promise.resolve({
            embeddings: [[0.1, 0.2, 0.3]],
            prompt_eval_count: 42,
          }),
      }),
    );

    const client = createEmbeddingClient({
      ollamaUrl: 'http://localhost:11434',
      audit,
    });
    const result = await client.embed('hello');
    expect(result).toBeInstanceOf(Float32Array);

    expect(audit.record).toHaveBeenCalledOnce();
    const call = audit.record.mock.calls[0][0];
    expect(call.caller).toBe('embedding');
    expect(call.operation).toBe('embed');
    expect(call.method).toBe('POST');
    expect(call.url).toBe('http://localhost:11434/api/embed');
    expect(call.statusCode).toBe(200);
    expect(call.model).toBe('nomic-embed-text');
    expect(call.provider).toBe('ollama');
    expect(call.promptTokens).toBe(42);
    expect(call.durationMs).toBeGreaterThanOrEqual(0);
    expect(call.meta).toEqual({ dimension: 768 });
  });

  it('Ollama error records audit with error field', async () => {
    const audit = makeAudit();
    vi.stubGlobal(
      'fetch',
      vi.fn().mockResolvedValue({
        ok: false,
        status: 500,
        json: () => Promise.resolve({}),
      }),
    );

    const client = createEmbeddingClient({
      ollamaUrl: 'http://localhost:11434',
      audit,
    });
    const result = await client.embed('hello');
    expect(result).toBeNull();

    expect(audit.record).toHaveBeenCalledOnce();
    const call = audit.record.mock.calls[0][0];
    expect(call.caller).toBe('embedding');
    expect(call.operation).toBe('embed');
    expect(call.statusCode).toBe(500);
    expect(call.error).toBe('HTTP 500');
    expect(call.provider).toBe('ollama');
  });

  it('Ollama fetch exception records audit with error', async () => {
    const audit = makeAudit();
    vi.stubGlobal(
      'fetch',
      vi.fn().mockRejectedValue(new Error('ECONNREFUSED')),
    );

    const client = createEmbeddingClient({
      ollamaUrl: 'http://localhost:11434',
      audit,
    });
    const result = await client.embed('hello');
    expect(result).toBeNull();

    expect(audit.record).toHaveBeenCalledOnce();
    const call = audit.record.mock.calls[0][0];
    expect(call.caller).toBe('embedding');
    expect(call.error).toBe('ECONNREFUSED');
    expect(call.statusCode).toBeUndefined();
  });

  it('OpenAI success records audit with usage.prompt_tokens', async () => {
    const audit = makeAudit();
    // Make Ollama fail first so we fall through to OpenAI
    vi.stubGlobal('fetch', vi.fn().mockRejectedValue(new Error('no ollama')));

    // Mock the OpenAI SDK via vi.hoisted + vi.mock
    const { mockCreate } = vi.hoisted(() => ({
      mockCreate: vi.fn().mockResolvedValue({
        data: [{ embedding: [0.1, 0.2, 0.3] }],
        usage: { prompt_tokens: 7, total_tokens: 7 },
      }),
    }));

    vi.mock('openai', () => ({
      default: class {
        embeddings = { create: mockCreate };
      },
    }));

    // Re-import after mock
    const { createEmbeddingClient: create } = await import(
      '../../src/core/embeddings.js'
    );
    const client = create({
      ollamaUrl: 'http://localhost:99999',
      openaiApiKey: 'sk-test',
      audit,
    });
    const result = await client.embed('hello');
    expect(result).toBeInstanceOf(Float32Array);

    // audit.record is called twice: once for Ollama error, once for OpenAI success
    const openaiCall = audit.record.mock.calls.find(
      (c: any) => c[0].provider === 'openai',
    );
    expect(openaiCall).toBeDefined();
    const call = openaiCall?.[0];
    expect(call.caller).toBe('embedding');
    expect(call.operation).toBe('embed');
    expect(call.model).toBe('text-embedding-3-small');
    expect(call.provider).toBe('openai');
    expect(call.promptTokens).toBe(7);
    // SDK path: no HTTP-level details
    expect(call.method).toBeUndefined();
    expect(call.url).toBeUndefined();
    expect(call.statusCode).toBeUndefined();

    vi.restoreAllMocks();
  });

  it('no audit writer does not crash', async () => {
    vi.stubGlobal(
      'fetch',
      vi.fn().mockResolvedValue({
        ok: true,
        json: () =>
          Promise.resolve({
            embeddings: [[0.1, 0.2, 0.3]],
            prompt_eval_count: 10,
          }),
      }),
    );

    const client = createEmbeddingClient({
      ollamaUrl: 'http://localhost:11434',
      // no audit passed
    });
    const result = await client.embed('hello');
    expect(result).toBeInstanceOf(Float32Array);
  });
});
