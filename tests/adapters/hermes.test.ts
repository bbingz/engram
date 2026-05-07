import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { describe, expect, it } from 'vitest';
import { HermesAdapter } from '../../src/adapters/hermes.js';

const __dirname = dirname(fileURLToPath(import.meta.url));
const FIXTURE = join(__dirname, '../fixtures/hermes/sample.json');
const DRIFT_FIXTURE = join(__dirname, '../fixtures/hermes/schema_drift.json');

describe('HermesAdapter', () => {
  const adapter = new HermesAdapter();

  it('name is hermes', () => {
    expect(adapter.name).toBe('hermes');
  });

  it('parseSessionInfo extracts metadata and skips preamble summary', async () => {
    const info = await adapter.parseSessionInfo(FIXTURE);
    expect(info?.id).toBe('hermes-session-001');
    expect(info?.source).toBe('hermes');
    expect(info?.cwd).toBe('/Users/test/hermes-project');
    expect(info?.project).toBe('Hermes');
    expect(info?.userMessageCount).toBe(1);
    expect(info?.systemMessageCount).toBe(1);
    expect(info?.toolMessageCount).toBe(2);
    expect(info?.summary).toBe('Summarize this task');
  });

  it('streamMessages emits assistant tool calls', async () => {
    const messages = [];
    for await (const msg of adapter.streamMessages(FIXTURE)) {
      messages.push(msg);
    }
    expect(messages).toHaveLength(4);
    expect(messages[2].role).toBe('assistant');
    expect(messages[2].toolCalls?.[0]?.name).toBe('read_file');
  });

  it('handles schema drift and model_config cwd fallback', async () => {
    const info = await adapter.parseSessionInfo(DRIFT_FIXTURE);
    expect(info?.cwd).toBe('/Users/test/hermes-project');
    const messages = [];
    for await (const msg of adapter.streamMessages(DRIFT_FIXTURE)) {
      messages.push(msg);
    }
    expect(messages.length).toBeGreaterThanOrEqual(2);
  });
});
