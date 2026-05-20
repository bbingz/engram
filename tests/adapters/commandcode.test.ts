import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { describe, expect, it } from 'vitest';
import { CommandCodeAdapter } from '../../src/adapters/commandcode.js';

const __dirname = dirname(fileURLToPath(import.meta.url));
const FIXTURE = join(__dirname, '../fixtures/commandcode/sample.jsonl');

describe('CommandCodeAdapter', () => {
  const adapter = new CommandCodeAdapter();

  it('name is commandcode', () => {
    expect(adapter.name).toBe('commandcode');
  });

  it('parseSessionInfo extracts role/content metadata', async () => {
    const info = await adapter.parseSessionInfo(FIXTURE);
    expect(info).toMatchObject({
      id: 'commandcode-session-001',
      source: 'commandcode',
      cwd: '/Users/test/my-project',
      model: 'command-code-agent',
      userMessageCount: 1,
      assistantMessageCount: 1,
      toolMessageCount: 1,
      summary: '检查解析器',
    });
  });

  it('streamMessages extracts text and tool calls', async () => {
    const messages = [];
    for await (const msg of adapter.streamMessages(FIXTURE)) messages.push(msg);
    expect(messages.map((m) => m.role)).toEqual(['user', 'assistant', 'tool']);
    expect(messages.flatMap((m) => m.toolCalls ?? [])[0]?.name).toBe(
      'read_file',
    );
  });
});
