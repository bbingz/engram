import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { describe, expect, it } from 'vitest';
import { CursorAdapter } from '../../src/adapters/cursor.js';

const __dirname = dirname(fileURLToPath(import.meta.url));
const FIXTURE_DB = join(__dirname, '../fixtures/cursor/state.vscdb');

describe('CursorAdapter', () => {
  const adapter = new CursorAdapter(FIXTURE_DB);

  it('name is cursor', () => {
    expect(adapter.name).toBe('cursor');
  });

  it('listSessionFiles yields virtual paths', async () => {
    const files: string[] = [];
    for await (const f of adapter.listSessionFiles()) {
      files.push(f);
    }
    expect(files).toHaveLength(1);
    expect(files[0]).toContain('abc-123');
  });

  it('parseSessionInfo returns session metadata', async () => {
    const files: string[] = [];
    for await (const f of adapter.listSessionFiles()) files.push(f);
    const info = await adapter.parseSessionInfo(files[0]);
    expect(info).not.toBeNull();
    expect(info?.id).toBe('abc-123');
    expect(info?.source).toBe('cursor');
    expect(info?.summary).toBe('Fix the login bug');
  });

  it('streamMessages yields user then assistant', async () => {
    const files: string[] = [];
    for await (const f of adapter.listSessionFiles()) files.push(f);
    const msgs: { role: string; content: string }[] = [];
    for await (const m of adapter.streamMessages(files[0])) msgs.push(m);
    expect(msgs).toHaveLength(2);
    expect(msgs[0]).toMatchObject({
      role: 'user',
      content: 'Fix the login bug',
    });
    expect(msgs[1]).toMatchObject({
      role: 'assistant',
      content: 'I found the issue in auth.ts',
    });
  });
});
