import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { describe, expect, it } from 'vitest';
import { VsCodeAdapter } from '../../src/adapters/vscode.js';

const __dirname = dirname(fileURLToPath(import.meta.url));
const FIXTURE_DIR = join(__dirname, '../fixtures/vscode');

describe('VsCodeAdapter', () => {
  const adapter = new VsCodeAdapter(FIXTURE_DIR);

  it('name is vscode', () => {
    expect(adapter.name).toBe('vscode');
  });

  it('listSessionFiles yields JSONL files from chatSessions subdirs', async () => {
    const files: string[] = [];
    for await (const f of adapter.listSessionFiles()) files.push(f);
    expect(files.some((f) => f.endsWith('sess-001.jsonl'))).toBe(true);
  });

  it('parseSessionInfo reads from JSONL first line', async () => {
    const jsonlPath = join(
      FIXTURE_DIR,
      'ws-abc123/chatSessions/sess-001.jsonl',
    );
    const info = await adapter.parseSessionInfo(jsonlPath);
    expect(info).not.toBeNull();
    expect(info?.id).toBe('sess-001');
    expect(info?.source).toBe('vscode');
    expect(info?.userMessageCount).toBe(2);
    expect(info?.summary).toContain('async/await');
  });

  it('streamMessages yields user and assistant alternating', async () => {
    const jsonlPath = join(
      FIXTURE_DIR,
      'ws-abc123/chatSessions/sess-001.jsonl',
    );
    const msgs: { role: string; content: string }[] = [];
    for await (const m of adapter.streamMessages(jsonlPath)) msgs.push(m);
    expect(msgs).toHaveLength(4);
    expect(msgs[0]).toMatchObject({
      role: 'user',
      content: 'How do I use async/await in TypeScript?',
    });
    expect(msgs[1].role).toBe('assistant');
    expect(msgs[2]).toMatchObject({
      role: 'user',
      content: 'Can you show an example?',
    });
    expect(msgs[3].role).toBe('assistant');
  });
});
