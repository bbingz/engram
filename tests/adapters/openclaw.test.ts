import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { describe, expect, it } from 'vitest';
import { OpenClawAdapter } from '../../src/adapters/openclaw.js';

const __dirname = dirname(fileURLToPath(import.meta.url));
const FIXTURE = join(__dirname, '../fixtures/openclaw/sample.jsonl');
const DRIFT_FIXTURE = join(
  __dirname,
  '../fixtures/openclaw/schema_drift.jsonl',
);

describe('OpenClawAdapter', () => {
  const adapter = new OpenClawAdapter();

  it('name is openclaw', () => {
    expect(adapter.name).toBe('openclaw');
  });

  it('parseSessionInfo extracts metadata and tool counts', async () => {
    const info = await adapter.parseSessionInfo(FIXTURE);
    expect(info?.id).toContain('openclaw:');
    expect(info?.source).toBe('openclaw');
    expect(info?.cwd).toBe('/Users/test/openclaw-project');
    expect(info?.userMessageCount).toBe(1);
    expect(info?.assistantMessageCount).toBe(1);
    expect(info?.toolMessageCount).toBe(2);
    expect(info?.summary).toBe('Review the deployment status');
  });

  it('streamMessages emits text, tool calls, and tool results', async () => {
    const messages = [];
    for await (const msg of adapter.streamMessages(FIXTURE)) {
      messages.push(msg);
    }
    expect(messages).toHaveLength(3);
    expect(messages[1].role).toBe('assistant');
    expect(messages[1].toolCalls?.[0]?.name).toBe('read_file');
    expect(messages[2].role).toBe('tool');
  });

  it('handles schema drift without object string leaks', async () => {
    const messages = [];
    for await (const msg of adapter.streamMessages(DRIFT_FIXTURE)) {
      messages.push(msg);
    }
    expect(messages.length).toBeGreaterThanOrEqual(2);
    expect(messages.map((m) => m.content).join('\n')).not.toContain(
      '[object Object]',
    );
  });
});
