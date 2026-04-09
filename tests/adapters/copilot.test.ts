// tests/adapters/copilot.test.ts

import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { describe, expect, it } from 'vitest';
import { CopilotAdapter } from '../../src/adapters/copilot.js';

const __dirname = dirname(fileURLToPath(import.meta.url));
const FIXTURE_DIR = join(__dirname, '../fixtures/copilot/session-1');
const FIXTURE = join(FIXTURE_DIR, 'events.jsonl');

describe('CopilotAdapter', () => {
  const adapter = new CopilotAdapter(join(__dirname, '../fixtures/copilot'));

  it('name is copilot', () => {
    expect(adapter.name).toBe('copilot');
  });

  it('parseSessionInfo extracts metadata from fixture', async () => {
    const info = await adapter.parseSessionInfo(FIXTURE);
    expect(info).not.toBeNull();
    expect(info?.id).toBe('test-session-1');
    expect(info?.source).toBe('copilot');
    expect(info?.cwd).toBe('/tmp/test-project');
    expect(info?.startTime).toBe('2026-01-01T00:00:00Z');
    expect(info?.userMessageCount).toBe(1);
    expect(info?.assistantMessageCount).toBe(1);
  });

  it('streamMessages yields user and assistant messages', async () => {
    const messages = [];
    for await (const msg of adapter.streamMessages(FIXTURE)) {
      messages.push(msg);
    }
    expect(messages.length).toBeGreaterThanOrEqual(2);
    expect(messages[0].role).toBe('user');
    expect(messages[0].content).toBe('Help me fix the bug');
    expect(messages[1].role).toBe('assistant');
    expect(messages[1].content).toBe("I'll look into that.");
  });

  it('streamMessages with limit: 1 yields only 1 message', async () => {
    const messages = [];
    for await (const msg of adapter.streamMessages(FIXTURE, { limit: 1 })) {
      messages.push(msg);
    }
    expect(messages).toHaveLength(1);
    expect(messages[0].role).toBe('user');
  });
});
