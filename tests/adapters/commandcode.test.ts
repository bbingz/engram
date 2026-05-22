import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
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

  describe('system injection classification (round-4 NEW-2)', () => {
    const tmpRoot = mkdtempSync(join(tmpdir(), 'engram-commandcode-'));
    const path = join(tmpRoot, 'inject.jsonl');

    beforeAll(() => {
      const lines = [
        // A real user message
        {
          id: 'm1',
          sessionId: 'cc-inject',
          role: 'user',
          cwd: '/x',
          content: [{ type: 'text', text: 'real question' }],
          timestamp: '2026-05-20T02:00:00.000Z',
        },
        // Claude-style injection wrappers — must count as system, not user
        ...[
          '<local-command-stdout>out</local-command-stdout>',
          '<command-name>foo</command-name>',
          'Unknown skill: foo',
          'Base directory for this skill: /x',
        ].map((text, i) => ({
          id: `s${i}`,
          sessionId: 'cc-inject',
          role: 'user',
          cwd: '/x',
          content: [{ type: 'text', text }],
          timestamp: `2026-05-20T02:0${i + 1}:00.000Z`,
        })),
      ];
      writeFileSync(
        path,
        `${lines.map((l) => JSON.stringify(l)).join('\n')}\n`,
      );
    });

    afterAll(() => rmSync(tmpRoot, { recursive: true, force: true }));

    it('counts injection wrappers as system, not user', async () => {
      const info = await adapter.parseSessionInfo(path);
      expect(info?.userMessageCount).toBe(1);
      expect(info?.systemMessageCount).toBe(4);
      expect(info?.summary).toBe('real question');
    });

    it('falls back to file mtime when no timestamp present', async () => {
      const noTsPath = join(tmpRoot, 'no-ts.jsonl');
      writeFileSync(
        noTsPath,
        `${JSON.stringify({
          id: 'm1',
          sessionId: 'cc-no-ts',
          role: 'user',
          cwd: '/x',
          content: [{ type: 'text', text: 'hi' }],
        })}\n`,
      );
      const info = await adapter.parseSessionInfo(noTsPath);
      expect(info?.startTime).toBeTruthy();
      expect(Number.isNaN(Date.parse(info?.startTime ?? ''))).toBe(false);
    });
  });
});
