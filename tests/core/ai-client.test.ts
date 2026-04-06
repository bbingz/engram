// tests/core/ai-client.test.ts
import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';

const {
  renderPromptTemplate,
  sampleMessages,
  buildRequestBody,
  summarizeConversation,
} = await import('../../src/core/ai-client.js');

// ── renderPromptTemplate ─────────────────────────────────────────────

describe('renderPromptTemplate', () => {
  it('default template with no overrides contains "3" and "中文", no {{', () => {
    const result = renderPromptTemplate({});
    expect(result).toContain('3');
    expect(result).toContain('中文');
    expect(result).not.toContain('{{');
  });

  it('custom language and sentences', () => {
    const result = renderPromptTemplate({
      summaryLanguage: 'English',
      summaryMaxSentences: 5,
    });
    expect(result).toContain('English');
    expect(result).toContain('5');
  });

  it('style included when provided', () => {
    const result = renderPromptTemplate({
      summaryStyle: 'bullets',
    });
    expect(result).toContain('风格要求：bullets');
  });

  it('style line removed when empty', () => {
    const result = renderPromptTemplate({});
    // No triple newlines (the style line should be stripped entirely)
    expect(result).not.toMatch(/\n\n\n/);
  });

  it('custom prompt template with variables', () => {
    const result = renderPromptTemplate({
      summaryPrompt: 'Summarize in {{language}} using {{maxSentences}} sentences. {{style}}',
      summaryLanguage: 'Japanese',
      summaryMaxSentences: 7,
      summaryStyle: 'prose',
    });
    expect(result).toBe('Summarize in Japanese using 7 sentences. 风格要求：prose');
  });
});

// ── sampleMessages ───────────────────────────────────────────────────

describe('sampleMessages', () => {
  it('under limit returns all messages', () => {
    const msgs = [
      { role: 'user', content: 'hello' },
      { role: 'assistant', content: 'hi there' },
    ];
    const result = sampleMessages(msgs, 10, 15, 500);
    expect(result).toHaveLength(2);
    expect(result[0].content).toBe('hello');
    expect(result[1].content).toBe('hi there');
  });

  it('over limit samples first N and last M', () => {
    const msgs = Array.from({ length: 100 }, (_, i) => ({
      role: i % 2 === 0 ? 'user' : 'assistant',
      content: `message ${i}`,
    }));
    const result = sampleMessages(msgs, 10, 15, 500);
    expect(result).toHaveLength(25);
    // First 10
    expect(result[0].content).toBe('message 0');
    expect(result[9].content).toBe('message 9');
    // Last 15
    expect(result[10].content).toBe('message 85');
    expect(result[24].content).toBe('message 99');
  });

  it('truncates long content', () => {
    const longContent = 'a'.repeat(1000);
    const msgs = [{ role: 'user', content: longContent }];
    const result = sampleMessages(msgs, 10, 15, 200);
    expect(result[0].content).toHaveLength(203); // 200 chars + "..."
    expect(result[0].content.endsWith('...')).toBe(true);
  });
});

// ── buildRequestBody ─────────────────────────────────────────────────

describe('buildRequestBody', () => {
  const opts = { model: 'test-model', maxTokens: 100, temperature: 0.3 };
  const system = 'You are a summarizer.';
  const conversation = '[user] hello\n\n[assistant] hi';

  it('openai: has model, 2 messages (system+user), max_tokens', () => {
    const body = buildRequestBody('openai', system, conversation, opts) as Record<string, unknown>;
    expect(body.model).toBe('test-model');
    expect(body.max_tokens).toBe(100);
    expect(body.temperature).toBe(0.3);
    const messages = body.messages as Array<{ role: string; content: string }>;
    expect(messages).toHaveLength(2);
    expect(messages[0].role).toBe('system');
    expect(messages[0].content).toBe(system);
    expect(messages[1].role).toBe('user');
    expect(messages[1].content).toContain(conversation);
  });

  it('anthropic: has model, system field, 1 message, max_tokens', () => {
    const body = buildRequestBody('anthropic', system, conversation, opts) as Record<string, unknown>;
    expect(body.model).toBe('test-model');
    expect(body.system).toBe(system);
    expect(body.max_tokens).toBe(100);
    expect(body.temperature).toBe(0.3);
    const messages = body.messages as Array<{ role: string; content: string }>;
    expect(messages).toHaveLength(1);
    expect(messages[0].role).toBe('user');
  });

  it('gemini: has systemInstruction, contents, generationConfig.maxOutputTokens', () => {
    const body = buildRequestBody('gemini', system, conversation, opts) as Record<string, unknown>;
    const sysInstr = body.systemInstruction as { parts: Array<{ text: string }> };
    expect(sysInstr.parts[0].text).toBe(system);
    const contents = body.contents as Array<{ role: string; parts: Array<{ text: string }> }>;
    expect(contents).toHaveLength(1);
    expect(contents[0].role).toBe('user');
    expect(contents[0].parts[0].text).toContain(conversation);
    const genConfig = body.generationConfig as { maxOutputTokens: number; temperature: number };
    expect(genConfig.maxOutputTokens).toBe(100);
    expect(genConfig.temperature).toBe(0.3);
    // No model or max_tokens at top level
    expect(body.model).toBeUndefined();
    expect(body.max_tokens).toBeUndefined();
  });
});

// ── summarizeConversation — audit integration ───────────────────────

describe('summarizeConversation audit', () => {
  const messages = [
    { role: 'user', content: 'Hello' },
    { role: 'assistant', content: 'Hi there' },
  ];
  const originalFetch = globalThis.fetch;

  afterEach(() => {
    globalThis.fetch = originalFetch;
  });

  function mockAudit() {
    const calls: any[] = [];
    return {
      record: (entry: any) => { calls.push(entry); return calls.length; },
      calls,
    };
  }

  it('openai: records audit with usage.prompt_tokens/completion_tokens', async () => {
    globalThis.fetch = vi.fn().mockResolvedValue({
      ok: true,
      status: 200,
      json: async () => ({
        choices: [{ message: { content: 'Summary text' } }],
        usage: { prompt_tokens: 150, completion_tokens: 50 },
      }),
    });

    const audit = mockAudit();
    const result = await summarizeConversation(messages, {
      aiProtocol: 'openai',
      aiApiKey: 'test-key',
      aiModel: 'gpt-4o-mini',
      aiBaseURL: 'http://localhost:8080',
    }, { audit: audit as any, sessionId: 'sess-1' });

    expect(result).toBe('Summary text');
    expect(audit.calls).toHaveLength(1);
    const entry = audit.calls[0];
    expect(entry.caller).toBe('summary');
    expect(entry.operation).toBe('summarize');
    expect(entry.method).toBe('POST');
    expect(entry.statusCode).toBe(200);
    expect(entry.model).toBe('gpt-4o-mini');
    expect(entry.provider).toBe('openai');
    expect(entry.promptTokens).toBe(150);
    expect(entry.completionTokens).toBe(50);
    expect(entry.totalTokens).toBe(200);
    expect(entry.sessionId).toBe('sess-1');
    expect(entry.durationMs).toBeGreaterThanOrEqual(0);
    expect(entry.url).toContain('/v1/chat/completions');
  });

  it('anthropic: records audit with usage.input_tokens/output_tokens', async () => {
    globalThis.fetch = vi.fn().mockResolvedValue({
      ok: true,
      status: 200,
      json: async () => ({
        content: [{ text: 'Anthropic summary' }],
        usage: { input_tokens: 200, output_tokens: 80 },
      }),
    });

    const audit = mockAudit();
    const result = await summarizeConversation(messages, {
      aiProtocol: 'anthropic',
      aiApiKey: 'test-key',
      aiModel: 'claude-sonnet-4-20250514',
      aiBaseURL: 'http://localhost:8080',
    }, { audit: audit as any });

    expect(result).toBe('Anthropic summary');
    expect(audit.calls).toHaveLength(1);
    const entry = audit.calls[0];
    expect(entry.provider).toBe('anthropic');
    expect(entry.promptTokens).toBe(200);
    expect(entry.completionTokens).toBe(80);
    expect(entry.totalTokens).toBe(280);
  });

  it('gemini: records audit with usageMetadata.promptTokenCount/candidatesTokenCount', async () => {
    globalThis.fetch = vi.fn().mockResolvedValue({
      ok: true,
      status: 200,
      json: async () => ({
        candidates: [{ content: { parts: [{ text: 'Gemini summary' }] } }],
        usageMetadata: { promptTokenCount: 300, candidatesTokenCount: 120 },
      }),
    });

    const audit = mockAudit();
    const result = await summarizeConversation(messages, {
      aiProtocol: 'gemini',
      aiApiKey: 'test-key',
      aiModel: 'gemini-pro',
      aiBaseURL: 'http://localhost:8080',
    }, { audit: audit as any });

    expect(result).toBe('Gemini summary');
    expect(audit.calls).toHaveLength(1);
    const entry = audit.calls[0];
    expect(entry.provider).toBe('gemini');
    expect(entry.promptTokens).toBe(300);
    expect(entry.completionTokens).toBe(120);
    expect(entry.totalTokens).toBe(420);
  });

  it('error response: records audit with error', async () => {
    globalThis.fetch = vi.fn().mockResolvedValue({
      ok: false,
      status: 429,
      text: async () => 'Rate limited',
    });

    const audit = mockAudit();
    await expect(summarizeConversation(messages, {
      aiProtocol: 'openai',
      aiApiKey: 'test-key',
      aiModel: 'gpt-4o-mini',
      aiBaseURL: 'http://localhost:8080',
    }, { audit: audit as any, sessionId: 'sess-err' })).rejects.toThrow('AI request failed (429)');

    expect(audit.calls).toHaveLength(1);
    const entry = audit.calls[0];
    expect(entry.caller).toBe('summary');
    expect(entry.statusCode).toBe(429);
    expect(entry.error).toContain('429');
    expect(entry.sessionId).toBe('sess-err');
  });

  it('fetch failure: records audit with network error', async () => {
    globalThis.fetch = vi.fn().mockRejectedValue(new Error('ECONNREFUSED'));

    const audit = mockAudit();
    await expect(summarizeConversation(messages, {
      aiProtocol: 'openai',
      aiApiKey: 'test-key',
      aiModel: 'gpt-4o-mini',
      aiBaseURL: 'http://localhost:8080',
    }, { audit: audit as any })).rejects.toThrow('ECONNREFUSED');

    expect(audit.calls).toHaveLength(1);
    const entry = audit.calls[0];
    expect(entry.caller).toBe('summary');
    expect(entry.error).toBe('ECONNREFUSED');
    expect(entry.statusCode).toBeUndefined();
  });

  it('no audit provided: does not crash', async () => {
    globalThis.fetch = vi.fn().mockResolvedValue({
      ok: true,
      status: 200,
      json: async () => ({
        choices: [{ message: { content: 'Works fine' } }],
        usage: { prompt_tokens: 10, completion_tokens: 5 },
      }),
    });

    // No opts at all
    const result1 = await summarizeConversation(messages, {
      aiProtocol: 'openai',
      aiApiKey: 'test-key',
      aiModel: 'gpt-4o-mini',
      aiBaseURL: 'http://localhost:8080',
    });
    expect(result1).toBe('Works fine');

    // Empty opts
    const result2 = await summarizeConversation(messages, {
      aiProtocol: 'openai',
      aiApiKey: 'test-key',
      aiModel: 'gpt-4o-mini',
      aiBaseURL: 'http://localhost:8080',
    }, {});
    expect(result2).toBe('Works fine');
  });

  it('no usage in response: records audit with undefined tokens', async () => {
    globalThis.fetch = vi.fn().mockResolvedValue({
      ok: true,
      status: 200,
      json: async () => ({
        choices: [{ message: { content: 'No usage' } }],
        // no usage field
      }),
    });

    const audit = mockAudit();
    await summarizeConversation(messages, {
      aiProtocol: 'openai',
      aiApiKey: 'test-key',
      aiModel: 'gpt-4o-mini',
      aiBaseURL: 'http://localhost:8080',
    }, { audit: audit as any });

    const entry = audit.calls[0];
    expect(entry.promptTokens).toBeUndefined();
    expect(entry.completionTokens).toBeUndefined();
    expect(entry.totalTokens).toBeUndefined(); // (0 + 0) || undefined = undefined
  });
});
