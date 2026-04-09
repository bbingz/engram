// tests/adapters/codex.test.ts

import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { describe, expect, it } from 'vitest';
import { CodexAdapter } from '../../src/adapters/codex.js';

const __dirname = dirname(fileURLToPath(import.meta.url));
const FIXTURE = join(__dirname, '../fixtures/codex/sample.jsonl');

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
