import { mkdirSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { describe, expect, it } from 'vitest';
import { QwenAdapter } from '../../src/adapters/qwen.js';

const __dirname = dirname(fileURLToPath(import.meta.url));
const FIXTURE = join(__dirname, '../fixtures/qwen/sample.jsonl');
const DRIFT_FIXTURE = join(__dirname, '../fixtures/qwen/schema_drift.jsonl');

describe('QwenAdapter', () => {
  const adapter = new QwenAdapter();

  it('name is qwen', () => {
    expect(adapter.name).toBe('qwen');
  });

  it('parseSessionInfo extracts metadata', async () => {
    const info = await adapter.parseSessionInfo(FIXTURE);
    expect(info).not.toBeNull();
    expect(info?.id).toBe('qwen-session-001');
    expect(info?.source).toBe('qwen');
    expect(info?.cwd).toBe('/Users/test/my-project');
    expect(info?.userMessageCount).toBe(2);
    expect(info?.summary).toBe('帮我重构这个模块');
  });

  it('streamMessages normalizes model role to assistant', async () => {
    const messages = [];
    for await (const msg of adapter.streamMessages(FIXTURE)) {
      messages.push(msg);
    }
    expect(messages[0].role).toBe('user');
    expect(messages[1].role).toBe('assistant');
  });

  it('parseSessionInfo falls back to message.model when top-level model is absent', async () => {
    const info = await adapter.parseSessionInfo(DRIFT_FIXTURE);
    expect(info?.model).toBe('qwen3-coder');
  });

  it('extractContent joins all text parts (multi-part messages keep full body)', async () => {
    const tmpRoot = join(tmpdir(), `engram-qwen-multi-${Date.now()}`);
    const filePath = join(tmpRoot, 'multi.jsonl');
    mkdirSync(tmpRoot, { recursive: true });
    writeFileSync(
      filePath,
      [
        JSON.stringify({
          uuid: 'u1',
          parentUuid: null,
          sessionId: 'multi-001',
          timestamp: '2026-04-01T00:00:00Z',
          type: 'user',
          cwd: '/x',
          message: {
            role: 'user',
            parts: [
              { text: 'first chunk' },
              { type: 'image', data: 'abc' },
              { text: 'second chunk' },
            ],
          },
        }),
      ].join('\n'),
    );
    try {
      const messages = [];
      for await (const m of adapter.streamMessages(filePath)) messages.push(m);
      expect(messages[0].content).toBe('first chunk\nsecond chunk');
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
