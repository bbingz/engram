import { mkdirSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { PiAdapter } from '../../src/adapters/pi.js';

describe('PiAdapter', () => {
  let root: string;
  let fixture: string;

  beforeEach(() => {
    root = join(tmpdir(), `engram-pi-${Date.now()}-${Math.random()}`);
    fixture = join(
      root,
      '--Users-test--project--',
      '2026-04-29T01-00-00-000Z_019dd6e3-91d1-7326-8299-314858773a0e.jsonl',
    );
    mkdirSync(dirname(fixture), { recursive: true });
    const lines = [
      {
        type: 'session',
        version: 1,
        id: '019dd6e3-91d1-7326-8299-314858773a0e',
        timestamp: '2026-04-29T01:00:00.000Z',
        cwd: '/Users/test/project',
      },
      {
        type: 'model_change',
        id: 'model-1',
        parentId: '019dd6e3-91d1-7326-8299-314858773a0e',
        timestamp: '2026-04-29T01:00:01.000Z',
        modelId: 'mimo-v2.5-pro',
      },
      {
        type: 'message',
        id: 'msg-user',
        parentId: '019dd6e3-91d1-7326-8299-314858773a0e',
        timestamp: '2026-04-29T01:00:02.000Z',
        message: {
          role: 'user',
          content: [{ type: 'text', text: 'Fix the Pi parser' }],
          timestamp: '2026-04-29T01:00:02.000Z',
        },
      },
      {
        type: 'message',
        id: 'msg-assistant',
        parentId: 'msg-user',
        timestamp: '2026-04-29T01:00:03.000Z',
        message: {
          role: 'assistant',
          content: [
            { type: 'text', text: 'I will inspect it.' },
            {
              type: 'toolCall',
              name: 'read',
              arguments: { path: '/Users/test/project/package.json' },
            },
          ],
          model: 'mimo-v2.5-pro',
          usage: { input: 10, output: 5, cacheRead: 2, cacheWrite: 1 },
          timestamp: '2026-04-29T01:00:03.000Z',
        },
      },
      {
        type: 'message',
        id: 'msg-tool',
        parentId: 'msg-assistant',
        timestamp: '2026-04-29T01:00:04.000Z',
        message: {
          role: 'toolResult',
          content: [{ type: 'text', text: '{"name":"fixture"}' }],
          timestamp: '2026-04-29T01:00:04.000Z',
        },
      },
    ].map((line) => JSON.stringify(line));
    writeFileSync(fixture, `${lines.join('\n')}\n`);
  });

  afterEach(() => {
    rmSync(root, { recursive: true, force: true });
  });

  it('lists nested session jsonl files', async () => {
    const adapter = new PiAdapter(root);
    const files: string[] = [];
    for await (const file of adapter.listSessionFiles()) files.push(file);
    expect(files).toEqual([fixture]);
  });

  it('parses Pi session metadata and streams normalized messages', async () => {
    const adapter = new PiAdapter(root);
    const info = await adapter.parseSessionInfo(fixture);

    expect(info).toMatchObject({
      id: '019dd6e3-91d1-7326-8299-314858773a0e',
      source: 'pi',
      startTime: '2026-04-29T01:00:00.000Z',
      endTime: '2026-04-29T01:00:04.000Z',
      cwd: '/Users/test/project',
      model: 'mimo-v2.5-pro',
      messageCount: 3,
      userMessageCount: 1,
      assistantMessageCount: 1,
      toolMessageCount: 1,
      summary: 'Fix the Pi parser',
    });

    const messages = [];
    for await (const message of adapter.streamMessages(fixture)) {
      messages.push(message);
    }

    expect(messages.map((message) => message.role)).toEqual([
      'user',
      'assistant',
      'tool',
    ]);
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
  });
});
