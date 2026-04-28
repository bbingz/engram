// tests/adapters/codex.test.ts

import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { describe, expect, it } from 'vitest';
import { CodexAdapter } from '../../src/adapters/codex.js';

const __dirname = dirname(fileURLToPath(import.meta.url));
const FIXTURE = join(__dirname, '../fixtures/codex/sample.jsonl');
const DRIFT_FIXTURE = join(__dirname, '../fixtures/codex/schema_drift.jsonl');

describe('CodexAdapter', () => {
  const adapter = new CodexAdapter();

  it('name is codex', () => {
    expect(adapter.name).toBe('codex');
  });

  it('parseSessionInfo extracts metadata', async () => {
    const info = await adapter.parseSessionInfo(FIXTURE);
    expect(info).not.toBeNull();
    expect(info?.id).toBe('codex-session-001');
    expect(info?.source).toBe('codex');
    expect(info?.cwd).toBe('/Users/test/my-project');
    expect(info?.startTime).toBe('2026-01-15T10:00:00.000Z');
    expect(info?.userMessageCount).toBe(2);
    expect(info?.summary).toBe('帮我修复登录 bug，用户无法登录');
  });

  it('counts function_call / function_call_output as tool messages', async () => {
    const info = await adapter.parseSessionInfo(FIXTURE);
    expect(info?.toolMessageCount).toBe(2);
    expect(info?.messageCount).toBe(
      (info?.userMessageCount ?? 0) +
        (info?.assistantMessageCount ?? 0) +
        (info?.toolMessageCount ?? 0),
    );
  });

  it('endTime tracks the last timestamped line, not the last user message', async () => {
    const info = await adapter.parseSessionInfo(FIXTURE);
    expect(info?.endTime).toBe('2026-01-15T10:05:00.000Z');
  });

  it('falls back to model_provider when response_item.payload.model is absent', async () => {
    const info = await adapter.parseSessionInfo(FIXTURE);
    expect(info?.model).toBe('openai');
  });

  it('prefers response_item.payload.model over session_meta.model_provider', async () => {
    const info = await adapter.parseSessionInfo(DRIFT_FIXTURE);
    expect(info?.model).toBe('gpt-4.1');
  });

  it('streamMessages yields user and assistant messages', async () => {
    const messages = [];
    for await (const msg of adapter.streamMessages(FIXTURE)) {
      messages.push(msg);
    }
    expect(messages.length).toBeGreaterThanOrEqual(3);
    expect(messages[0].role).toBe('user');
    expect(messages[0].content).toBe('帮我修复登录 bug，用户无法登录');
    expect(messages[1].role).toBe('assistant');
  });

  it('streamMessages yields tool role for function_call and function_call_output', async () => {
    const messages = [];
    for await (const msg of adapter.streamMessages(FIXTURE)) {
      messages.push(msg);
    }
    const tools = messages.filter((m) => m.role === 'tool');
    expect(tools).toHaveLength(2);
    expect(tools[0].toolCalls?.[0]?.name).toBe('read_file');
    expect(tools[0].toolCalls?.[0]?.input).toContain('src/auth.ts');
    expect(tools[1].content).toBe('// auth.ts content...');
  });

  it('maps assistant payload.usage onto Message.usage', async () => {
    const messages = [];
    for await (const msg of adapter.streamMessages(DRIFT_FIXTURE)) {
      messages.push(msg);
    }
    const assistant = messages.find((m) => m.role === 'assistant');
    expect(assistant?.usage).toBeDefined();
    expect(assistant?.usage?.inputTokens).toBe(50);
    expect(assistant?.usage?.outputTokens).toBe(30);
  });

  it('streamMessages respects offset and limit', async () => {
    const messages = [];
    for await (const msg of adapter.streamMessages(FIXTURE, {
      offset: 1,
      limit: 1,
    })) {
      messages.push(msg);
    }
    expect(messages).toHaveLength(1);
    expect(messages[0].role).toBe('assistant');
  });
});
