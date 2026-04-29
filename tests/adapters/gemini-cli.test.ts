// tests/adapters/gemini-cli.test.ts

import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { describe, expect, it } from 'vitest';
import { GeminiCliAdapter } from '../../src/adapters/gemini-cli.js';

const __dirname = dirname(fileURLToPath(import.meta.url));
const FIXTURE_DIR = join(__dirname, '../fixtures/gemini');
const SESSION_FIXTURE = join(FIXTURE_DIR, 'session-sample.json');
const PROJECTS_FIXTURE = join(FIXTURE_DIR, 'projects.json');

describe('GeminiCliAdapter', () => {
  const adapter = new GeminiCliAdapter(FIXTURE_DIR, PROJECTS_FIXTURE);

  it('name is gemini-cli', () => {
    expect(adapter.name).toBe('gemini-cli');
  });

  it('parseSessionInfo extracts metadata', async () => {
    const info = await adapter.parseSessionInfo(SESSION_FIXTURE);
    expect(info).not.toBeNull();
    expect(info?.id).toBe('gemini-session-001');
    expect(info?.source).toBe('gemini-cli');
    expect(info?.startTime).toBe('2026-01-25T14:00:00.000Z');
    expect(info?.userMessageCount).toBe(2);
    expect(info?.summary).toBe('帮我优化这段 SQL 查询');
  });

  it('streamMessages yields only user and gemini messages (not info)', async () => {
    const messages = [];
    for await (const msg of adapter.streamMessages(SESSION_FIXTURE)) {
      messages.push(msg);
    }
    expect(messages).toHaveLength(3); // 2 user + 1 gemini，info 被过滤
    expect(
      messages.every((m) => m.role === 'user' || m.role === 'assistant'),
    ).toBe(true);
    expect(messages[0].content).toBe('帮我优化这段 SQL 查询');
    expect(messages[1].role).toBe('assistant');
  });

  it('resolveProject returns cwd for projectName', async () => {
    const cwd = await adapter.resolveProject('my-project');
    expect(cwd).toBe('/Users/test/my-project');
  });
});
