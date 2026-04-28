import { mkdirSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { describe, expect, it } from 'vitest';
import { IflowAdapter } from '../../src/adapters/iflow.js';

const __dirname = dirname(fileURLToPath(import.meta.url));
const FIXTURE = join(__dirname, '../fixtures/iflow/sample.jsonl');

describe('IflowAdapter', () => {
  const adapter = new IflowAdapter();

  it('name is iflow', () => {
    expect(adapter.name).toBe('iflow');
  });

  it('parseSessionInfo extracts metadata', async () => {
    const info = await adapter.parseSessionInfo(FIXTURE);
    expect(info).not.toBeNull();
    expect(info?.id).toBe('session-iflow-001');
    expect(info?.source).toBe('iflow');
    expect(info?.cwd).toBe('/Users/test/my-project');
    expect(info?.startTime).toBe('2026-01-20T09:00:00.000Z');
    expect(info?.userMessageCount).toBe(2);
    expect(info?.summary).toBe('帮我优化数据库查询');
  });

  it('parseSessionInfo extracts model from assistant message', async () => {
    const info = await adapter.parseSessionInfo(FIXTURE);
    expect(info?.model).toBe('glm-5');
  });

  it('streamMessages yields user and assistant', async () => {
    const messages = [];
    for await (const msg of adapter.streamMessages(FIXTURE)) {
      messages.push(msg);
    }
    expect(messages.length).toBeGreaterThanOrEqual(2);
    expect(messages[0].role).toBe('user');
    expect(messages[0].content).toBe('帮我优化数据库查询');
    expect(messages[1].role).toBe('assistant');
  });

  it('extractContent joins all text parts in array content', async () => {
    const tmpRoot = join(tmpdir(), `engram-iflow-multi-${Date.now()}`);
    const filePath = join(tmpRoot, 'multi.jsonl');
    mkdirSync(tmpRoot, { recursive: true });
    writeFileSync(
      filePath,
      [
        JSON.stringify({
          uuid: 'u1',
          parentUuid: null,
          sessionId: 'iflow-multi',
          timestamp: '2026-04-01T00:00:00.000Z',
          type: 'user',
          cwd: '/x',
          message: {
            role: 'user',
            content: [
              { type: 'text', text: 'first' },
              { type: 'image', data: 'xx' },
              { type: 'text', text: 'second' },
            ],
          },
        }),
      ].join('\n'),
    );
    try {
      const messages = [];
      for await (const m of adapter.streamMessages(filePath)) messages.push(m);
      expect(messages[0].content).toBe('first\nsecond');
    } finally {
      rmSync(tmpRoot, { recursive: true, force: true });
    }
  });

  it('streamMessages respects limit', async () => {
    const messages = [];
    for await (const msg of adapter.streamMessages(FIXTURE, { limit: 1 })) {
      messages.push(msg);
    }
    expect(messages).toHaveLength(1);
  });
});
