import { afterEach, describe, expect, it, vi } from 'vitest';
import type { AiAuditWriter } from '../../src/core/ai-audit.js';
import {
  buildTitlePrompt,
  parseTitleResponse,
  TitleGenerator,
} from '../../src/core/title-generator.js';

describe('title-generator', () => {
  it('builds prompt from conversation turns', () => {
    const prompt = buildTitlePrompt([
      { role: 'user', content: '请帮我重构这个 Button 组件' },
      { role: 'assistant', content: '好的，我来看一下代码结构...' },
    ]);
    expect(prompt).toContain('Generate a concise title');
    expect(prompt).toContain('≤30 characters');
    expect(prompt).toContain('重构');
  });

  it('truncates long messages to 200 chars', () => {
    const longMsg = 'a'.repeat(500);
    const prompt = buildTitlePrompt([{ role: 'user', content: longMsg }]);
    expect(prompt.length).toBeLessThan(600);
  });

  it('parses clean title', () => {
    expect(parseTitleResponse('重构 Button 组件')).toBe('重构 Button 组件');
  });

  it('removes quotes', () => {
    expect(parseTitleResponse('"Fix login bug"')).toBe('Fix login bug');
  });

  it('removes Title: prefix', () => {
    expect(parseTitleResponse('Title: Add caching\n')).toBe('Add caching');
  });

  it('removes 标题: prefix', () => {
    expect(parseTitleResponse('标题：修复登录问题')).toBe('修复登录问题');
  });

  it('truncates to 30 chars', () => {
    const long =
      'A very long title that exceeds thirty characters by quite a lot';
    expect(parseTitleResponse(long).length).toBeLessThanOrEqual(30);
  });
});

describe('TitleGenerator audit', () => {
  const messages = [
    { role: 'user', content: 'Fix the login bug' },
    { role: 'assistant', content: 'Sure, let me look...' },
  ];

  function makeAudit() {
    return {
      record: vi.fn().mockReturnValue(1),
    } as unknown as AiAuditWriter & { record: ReturnType<typeof vi.fn> };
  }

  afterEach(() => {
    vi.unstubAllGlobals();
  });

  it('records audit with Ollama token fields', async () => {
    const audit = makeAudit();
    vi.stubGlobal(
      'fetch',
      vi.fn().mockResolvedValue({
        status: 200,
        json: () =>
          Promise.resolve({
            response: 'Ollama Title',
            prompt_eval_count: 120,
            eval_count: 15,
          }),
      }),
    );

    const gen = new TitleGenerator({
      provider: 'ollama',
      baseUrl: 'http://localhost:11434',
      model: 'qwen2.5:3b',
      autoGenerate: true,
      audit,
    });
    const title = await gen.generate(messages);
    expect(title).toBe('Ollama Title');

    expect(audit.record).toHaveBeenCalledOnce();
    const call = audit.record.mock.calls[0][0];
    expect(call.caller).toBe('title');
    expect(call.operation).toBe('generate');
    expect(call.statusCode).toBe(200);
    expect(call.promptTokens).toBe(120);
    expect(call.completionTokens).toBe(15);
    expect(call.totalTokens).toBe(135);
    expect(call.model).toBe('qwen2.5:3b');
    expect(call.provider).toBe('ollama');
    expect(call.url).toContain('/api/generate');
    expect(call.responseBody).toEqual({ text: 'Ollama Title' });
  });

  it('records audit with OpenAI usage fields', async () => {
    const audit = makeAudit();
    vi.stubGlobal(
      'fetch',
      vi.fn().mockResolvedValue({
        status: 200,
        json: () =>
          Promise.resolve({
            choices: [{ message: { content: 'OpenAI Title' } }],
            usage: { prompt_tokens: 80, completion_tokens: 10 },
          }),
      }),
    );

    const gen = new TitleGenerator({
      provider: 'openai',
      baseUrl: 'https://api.openai.com',
      model: 'gpt-4o-mini',
      apiKey: 'sk-test',
      autoGenerate: true,
      audit,
    });
    const title = await gen.generate(messages);
    expect(title).toBe('OpenAI Title');

    expect(audit.record).toHaveBeenCalledOnce();
    const call = audit.record.mock.calls[0][0];
    expect(call.promptTokens).toBe(80);
    expect(call.completionTokens).toBe(10);
    expect(call.totalTokens).toBe(90);
    expect(call.provider).toBe('openai');
    expect(call.url).toContain('/v1/chat/completions');
  });

  it('records audit with error on fetch failure', async () => {
    const audit = makeAudit();
    vi.stubGlobal(
      'fetch',
      vi.fn().mockRejectedValue(new Error('ECONNREFUSED')),
    );

    const gen = new TitleGenerator({
      provider: 'ollama',
      baseUrl: 'http://localhost:11434',
      model: 'qwen2.5:3b',
      autoGenerate: true,
      audit,
    });
    const title = await gen.generate(messages);
    expect(title).toBeNull(); // generate() catches and returns null

    expect(audit.record).toHaveBeenCalledOnce();
    const call = audit.record.mock.calls[0][0];
    expect(call.caller).toBe('title');
    expect(call.error).toBe('ECONNREFUSED');
    expect(call.statusCode).toBeUndefined();
    expect(call.durationMs).toBeGreaterThanOrEqual(0);
  });

  it('does not crash when no audit is provided', async () => {
    vi.stubGlobal(
      'fetch',
      vi.fn().mockResolvedValue({
        status: 200,
        json: () => Promise.resolve({ response: 'No Audit' }),
      }),
    );

    const gen = new TitleGenerator({
      provider: 'ollama',
      baseUrl: 'http://localhost:11434',
      model: 'qwen2.5:3b',
      autoGenerate: true,
      // no audit
    });
    const title = await gen.generate(messages);
    expect(title).toBe('No Audit');
  });

  it('records undefined totalTokens when both counts are missing', async () => {
    const audit = makeAudit();
    vi.stubGlobal(
      'fetch',
      vi.fn().mockResolvedValue({
        status: 200,
        json: () =>
          Promise.resolve({
            choices: [{ message: { content: 'No Usage' } }],
            // no usage field
          }),
      }),
    );

    const gen = new TitleGenerator({
      provider: 'openai',
      baseUrl: 'https://api.openai.com',
      model: 'gpt-4o-mini',
      autoGenerate: true,
      audit,
    });
    await gen.generate(messages);

    const call = audit.record.mock.calls[0][0];
    expect(call.promptTokens).toBeUndefined();
    expect(call.completionTokens).toBeUndefined();
    expect(call.totalTokens).toBeUndefined(); // (0 + 0) || undefined = undefined
  });
});
