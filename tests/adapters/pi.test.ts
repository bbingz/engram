import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { describe, expect, it } from 'vitest';
import { PiAdapter } from '../../src/adapters/pi.js';

const __dirname = dirname(fileURLToPath(import.meta.url));
const FIXTURE_ROOT = join(__dirname, '../fixtures/pi/sessions');
const FIXTURE = join(
  FIXTURE_ROOT,
  '--Users-test--project--',
  '2026-04-29T01-00-00-000Z_019dd6e3-91d1-7326-8299-314858773a0e.jsonl',
);

describe('PiAdapter', () => {
  const adapter = new PiAdapter(FIXTURE_ROOT);

  it('name is pi', () => {
    expect(adapter.name).toBe('pi');
  });

  it('lists nested session jsonl files', async () => {
    const files: string[] = [];
    for await (const file of adapter.listSessionFiles()) files.push(file);
    expect(files).toContain(FIXTURE);
  });

  it('parseSessionInfo extracts metadata and counts roles', async () => {
    const info = await adapter.parseSessionInfo(FIXTURE);
    expect(info).not.toBeNull();
    expect(info?.id).toBe('019dd6e3-91d1-7326-8299-314858773a0e');
    expect(info?.source).toBe('pi');
    expect(info?.startTime).toBe('2026-04-29T01:00:00.000Z');
    expect(info?.endTime).toBe('2026-04-29T01:00:05.000Z');
    expect(info?.cwd).toBe('/Users/test/project');
    expect(info?.model).toBe('gpt-5.4');
    expect(info?.messageCount).toBe(4);
    expect(info?.userMessageCount).toBe(2);
    expect(info?.assistantMessageCount).toBe(1);
    expect(info?.toolMessageCount).toBe(1);
    expect(info?.systemMessageCount).toBe(0);
    expect(info?.summary).toBe('Fix the Pi parser');
  });

  it('streamMessages yields normalized messages and token usage', async () => {
    const messages = [];
    for await (const msg of adapter.streamMessages(FIXTURE)) messages.push(msg);

    expect(messages).toHaveLength(4);
    expect(messages[0]).toMatchObject({
      role: 'user',
      content: 'Fix the Pi parser',
      timestamp: '2026-04-29T01:00:02.000Z',
    });
    expect(messages[1]).toMatchObject({
      role: 'assistant',
      content: 'I will inspect it.',
      usage: {
        inputTokens: 10,
        outputTokens: 5,
        cacheReadTokens: 2,
        cacheCreationTokens: 1,
      },
    });
    expect(messages[1].toolCalls?.[0]).toMatchObject({
      name: 'read',
      input: '{"path":"/Users/test/project/package.json"}',
    });
    expect(messages[2]).toMatchObject({
      role: 'tool',
      content: '{"name":"fixture"}',
    });
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
