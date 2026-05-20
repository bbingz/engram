import { mkdir, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { describe, expect, it } from 'vitest';
import { QoderAdapter } from '../../src/adapters/qoder.js';

const __dirname = dirname(fileURLToPath(import.meta.url));
const FIXTURE = join(__dirname, '../fixtures/qoder/sample.jsonl');

describe('QoderAdapter', () => {
  const adapter = new QoderAdapter();

  it('name is qoder', () => {
    expect(adapter.name).toBe('qoder');
  });

  it('parseSessionInfo extracts Claude-compatible metadata', async () => {
    const info = await adapter.parseSessionInfo(FIXTURE);
    expect(info).toMatchObject({
      id: 'qoder-session-001',
      source: 'qoder',
      cwd: '/Users/test/my-project',
      userMessageCount: 1,
      assistantMessageCount: 2,
      toolMessageCount: 1,
      summary: 'Review the parser',
    });
  });

  it('streamMessages preserves user assistant and tool roles', async () => {
    const messages = [];
    for await (const msg of adapter.streamMessages(FIXTURE)) messages.push(msg);
    expect(messages.map((m) => m.role)).toEqual([
      'user',
      'assistant',
      'assistant',
      'tool',
    ]);
    expect(messages.flatMap((m) => m.toolCalls ?? [])[0]?.name).toBe('Read');
    expect(messages[3].content).toBe('file contents omitted');
  });

  it('lists nested subagents with parent session ids', async () => {
    const root = await mkdtemp(join(tmpdir(), 'qoder-subagents-'));
    try {
      const sessionDir = join(
        root,
        '-Volumes-work-my-project',
        'parent-session',
      );
      const subagentDir = join(sessionDir, 'subagents');
      await mkdir(subagentDir, { recursive: true });
      await writeFile(
        join(subagentDir, 'subagent.jsonl'),
        await readFile(FIXTURE),
      );

      const nestedAdapter = new QoderAdapter(root);
      const files: string[] = [];
      for await (const file of nestedAdapter.listSessionFiles())
        files.push(file);
      expect(files).toEqual([join(subagentDir, 'subagent.jsonl')]);
      const info = await nestedAdapter.parseSessionInfo(files[0]);
      expect(info?.parentSessionId).toBe('parent-session');
    } finally {
      await rm(root, { recursive: true, force: true });
    }
  });

  it('does not invent parent session ids for project-level subagents', async () => {
    const root = await mkdtemp(join(tmpdir(), 'qoder-direct-subagents-'));
    try {
      const subagentDir = join(root, '-Volumes-work-my-project', 'subagents');
      await mkdir(subagentDir, { recursive: true });
      await writeFile(
        join(subagentDir, 'subagent.jsonl'),
        await readFile(FIXTURE),
      );

      const directAdapter = new QoderAdapter(root);
      const files: string[] = [];
      for await (const file of directAdapter.listSessionFiles())
        files.push(file);
      expect(files).toEqual([join(subagentDir, 'subagent.jsonl')]);
      const info = await directAdapter.parseSessionInfo(files[0]);
      expect(info?.parentSessionId).toBeUndefined();
    } finally {
      await rm(root, { recursive: true, force: true });
    }
  });
});
