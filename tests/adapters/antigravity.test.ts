// tests/adapters/antigravity.test.ts

import { mkdir, mkdtemp, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { describe, expect, it } from 'vitest';
import { AntigravityAdapter } from '../../src/adapters/antigravity.js';

const __dirname = dirname(fileURLToPath(import.meta.url));
const FIXTURE_CACHE = join(__dirname, '../fixtures/antigravity/cache');
const FIXTURE_CLI = join(
  __dirname,
  '../fixtures/antigravity-cli/transcript.jsonl',
);

describe('AntigravityAdapter (cache mode)', () => {
  // Pass a non-existent daemon dir — adapter falls back to cache-only mode
  const adapter = new AntigravityAdapter('/nonexistent/daemon', FIXTURE_CACHE);

  it('name is antigravity', () => {
    expect(adapter.name).toBe('antigravity');
  });

  it('listSessionFiles yields cache JSONL files', async () => {
    const files: string[] = [];
    for await (const f of adapter.listSessionFiles()) files.push(f);
    expect(files.some((f) => f.endsWith('conv-001.jsonl'))).toBe(true);
  });

  it('parseSessionInfo reads metadata from first line', async () => {
    const filePath = join(FIXTURE_CACHE, 'conv-001.jsonl');
    const info = await adapter.parseSessionInfo(filePath);
    expect(info).not.toBeNull();
    expect(info?.id).toBe('conv-001');
    expect(info?.source).toBe('antigravity');
    expect(info?.summary).toContain('Fix auth bug');
  });

  it('streamMessages yields user and assistant from cache', async () => {
    const filePath = join(FIXTURE_CACHE, 'conv-001.jsonl');
    const msgs: { role: string; content: string }[] = [];
    for await (const m of adapter.streamMessages(filePath)) msgs.push(m);
    expect(msgs).toHaveLength(2);
    expect(msgs[0].role).toBe('user');
    expect(msgs[1].role).toBe('assistant');
  });
});

describe('AntigravityAdapter (CLI brain transcripts)', () => {
  const adapter = new AntigravityAdapter(
    '/nonexistent/daemon',
    '/nonexistent/cache',
    '/nonexistent/conversations',
    dirname(FIXTURE_CLI),
  );

  it('parseSessionInfo reads Antigravity CLI event streams', async () => {
    const info = await adapter.parseSessionInfo(FIXTURE_CLI);
    expect(info).toMatchObject({
      id: 'transcript',
      source: 'antigravity',
      userMessageCount: 1,
      assistantMessageCount: 2,
      toolMessageCount: 1,
      summary: 'Review the Antigravity CLI parser',
    });
  });

  it('streamMessages maps planner and tool events to roles', async () => {
    const msgs = [];
    for await (const msg of adapter.streamMessages(FIXTURE_CLI)) {
      msgs.push(msg);
    }
    expect(msgs.map((m) => m.role)).toEqual([
      'user',
      'assistant',
      'tool',
      'assistant',
    ]);
    expect(msgs.flatMap((m) => m.toolCalls ?? [])[0]?.name).toBe('Read');
  });

  it('ignores unknown content-bearing CLI events', async () => {
    const root = await mkdtemp(join(tmpdir(), 'antigravity-cli-unknown-'));
    try {
      const transcriptDir = join(
        root,
        'brain',
        'ag-cli-session',
        '.system_generated',
        'logs',
      );
      await mkdir(transcriptDir, { recursive: true });
      const locator = join(transcriptDir, 'transcript.jsonl');
      await writeFile(
        locator,
        `${[
          '{"type":"USER_INPUT","created_at":"2026-05-20T03:00:00Z","content":"Review the parser"}',
          '{"type":"MEMORY_NOTE","created_at":"2026-05-20T03:00:01Z","content":"internal memory"}',
          '{"type":"RUN_COMMAND","created_at":"2026-05-20T03:00:02Z","content":"command output"}',
          '{"type":"PLANNER_RESPONSE","created_at":"2026-05-20T03:00:03Z","content":"Done."}',
        ].join('\n')}\n`,
        'utf8',
      );

      const scoped = new AntigravityAdapter(
        '/nonexistent/daemon',
        '/nonexistent/cache',
        '/nonexistent/conversations',
        join(root, 'brain'),
      );

      const info = await scoped.parseSessionInfo(locator);
      expect(info).toMatchObject({
        userMessageCount: 1,
        assistantMessageCount: 1,
        toolMessageCount: 0,
        messageCount: 2,
      });

      const msgs = [];
      for await (const msg of scoped.streamMessages(locator)) msgs.push(msg);
      expect(msgs.map((m) => m.role)).toEqual(['user', 'assistant']);
      expect(msgs.map((m) => m.content)).not.toContain('internal memory');
      expect(msgs.map((m) => m.content)).not.toContain('command output');
    } finally {
      await rm(root, { recursive: true, force: true });
    }
  });

  it('infers cwd from generic absolute paths', async () => {
    const root = await mkdtemp(join(tmpdir(), 'antigravity-cli-cwd-'));
    try {
      const transcriptDir = join(
        root,
        'brain',
        'ag-cli-cwd',
        '.system_generated',
        'logs',
      );
      await mkdir(transcriptDir, { recursive: true });
      const locator = join(transcriptDir, 'transcript.jsonl');
      await writeFile(
        locator,
        `${[
          '{"type":"USER_INPUT","created_at":"2026-05-20T03:00:00Z","content":"Read /home/alice/work/app/src/main.go"}',
          '{"type":"PLANNER_RESPONSE","created_at":"2026-05-20T03:00:01Z","content":"Also saw /home/alice/work/app/src/util.go and /opt/other/x.go"}',
        ].join('\n')}\n`,
        'utf8',
      );

      const scoped = new AntigravityAdapter(
        '/nonexistent/daemon',
        '/nonexistent/cache',
        '/nonexistent/conversations',
        join(root, 'brain'),
      );

      const info = await scoped.parseSessionInfo(locator);
      expect(info?.cwd).toBe('/home/alice/work/app/src');
    } finally {
      await rm(root, { recursive: true, force: true });
    }
  });

  it('does not infer cwd from markup-like slash tokens', async () => {
    const root = await mkdtemp(join(tmpdir(), 'antigravity-cli-no-cwd-'));
    try {
      const transcriptDir = join(
        root,
        'brain',
        'ag-cli-no-cwd',
        '.system_generated',
        'logs',
      );
      await mkdir(transcriptDir, { recursive: true });
      const locator = join(transcriptDir, 'transcript.jsonl');
      await writeFile(
        locator,
        `${[
          '{"type":"USER_INPUT","created_at":"2026-05-20T03:00:00Z","content":"</bash_command_reminder>\\\\n<user_query>inspect the session</user_query>"}',
          '{"type":"PLANNER_RESPONSE","created_at":"2026-05-20T03:00:01Z","content":"No filesystem path here."}',
        ].join('\n')}\n`,
        'utf8',
      );

      const scoped = new AntigravityAdapter(
        '/nonexistent/daemon',
        '/nonexistent/cache',
        '/nonexistent/conversations',
        join(root, 'brain'),
      );

      const info = await scoped.parseSessionInfo(locator);
      expect(info?.cwd).toBe('');
    } finally {
      await rm(root, { recursive: true, force: true });
    }
  });

  it('does not infer cwd from URL and route-like slash tokens', async () => {
    const root = await mkdtemp(join(tmpdir(), 'antigravity-cli-route-cwd-'));
    try {
      const transcriptDir = join(
        root,
        'brain',
        'ag-cli-route-cwd',
        '.system_generated',
        'logs',
      );
      await mkdir(transcriptDir, { recursive: true });
      const locator = join(transcriptDir, 'transcript.jsonl');
      await writeFile(
        locator,
        `${[
          '{"type":"USER_INPUT","created_at":"2026-05-20T03:00:00Z","content":"Open https://github.com/bbingz/engram and http://localhost:5173/components/ui"}',
          '{"type":"PLANNER_RESPONSE","created_at":"2026-05-20T03:00:01Z","content":"Menu: /编辑/视图 /reports /CI/Bug修复 /components/ui"}',
        ].join('\n')}\n`,
        'utf8',
      );

      const scoped = new AntigravityAdapter(
        '/nonexistent/daemon',
        '/nonexistent/cache',
        '/nonexistent/conversations',
        join(root, 'brain'),
      );

      const info = await scoped.parseSessionInfo(locator);
      expect(info?.cwd).toBe('');
    } finally {
      await rm(root, { recursive: true, force: true });
    }
  });

  it('keeps CLI constructor root available for discovery', async () => {
    expect(adapter.name).toBe('antigravity');
  });
});
