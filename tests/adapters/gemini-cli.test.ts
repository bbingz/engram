// tests/adapters/gemini-cli.test.ts

import {
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  statSync,
  utimesSync,
  writeFileSync,
} from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { afterEach, describe, expect, it } from 'vitest';
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

  it('lists and replays current JSONL event logs', async () => {
    const tmp = mkdtempSync(join(tmpdir(), 'engram-gemini-jsonl-'));
    try {
      const projectDir = join(tmp, 'tmp', 'hash-001');
      const chatsDir = join(projectDir, 'chats');
      mkdirSync(chatsDir, { recursive: true });
      writeFileSync(
        join(projectDir, '.project_root'),
        '/Users/test/gemini-jsonl',
      );
      const jsonlPath = join(chatsDir, 'jsonl-session-001.jsonl');
      writeFileSync(
        jsonlPath,
        [
          JSON.stringify({
            kind: 'main',
            sessionId: 'jsonl-session-001',
            projectHash: 'hash-001',
            startTime: '2026-06-21T01:33:00.000Z',
            lastUpdated: '2026-06-21T01:33:00.000Z',
          }),
          JSON.stringify({
            id: 'm1',
            timestamp: '2026-06-21T01:33:05.000Z',
            type: 'user',
            content: [{ text: 'jsonl prompt' }],
          }),
          JSON.stringify({
            id: 'm2',
            timestamp: '2026-06-21T01:33:09.000Z',
            type: 'gemini',
            content: 'jsonl answer',
          }),
          JSON.stringify({
            $set: {
              lastUpdated: '2026-06-21T01:33:09.000Z',
              summary: 'derived jsonl title',
            },
          }),
          '',
        ].join('\n'),
      );
      writeFileSync(
        join(chatsDir, 'jsonl-session-001.engram.json'),
        JSON.stringify({ originator: 'claude-code' }),
      );

      const adapter = new GeminiCliAdapter(
        join(tmp, 'tmp'),
        join(tmp, 'no.json'),
      );
      const files: string[] = [];
      for await (const file of adapter.listSessionFiles()) files.push(file);
      expect(files).toEqual([jsonlPath]);

      const info = await adapter.parseSessionInfo(jsonlPath);
      expect(info).toMatchObject({
        id: 'jsonl-session-001',
        cwd: '/Users/test/gemini-jsonl',
        userMessageCount: 1,
        assistantMessageCount: 1,
        summary: 'jsonl prompt',
        endTime: '2026-06-21T01:33:09.000Z',
      });

      const messages = [];
      for await (const msg of adapter.streamMessages(jsonlPath))
        messages.push(msg);
      expect(messages.map((msg) => msg.content)).toEqual([
        'jsonl prompt',
        'jsonl answer',
      ]);
    } finally {
      rmSync(tmp, { recursive: true, force: true });
    }
  });

  it('lists native nested subagent JSONL files with parent links', async () => {
    const tmp = mkdtempSync(join(tmpdir(), 'engram-gemini-subagent-'));
    try {
      const projectDir = join(tmp, 'tmp', 'hash-001');
      const subagentDir = join(projectDir, 'chats', 'parent-session-001');
      mkdirSync(subagentDir, { recursive: true });
      writeFileSync(join(projectDir, '.project_root'), '/Users/test/gemini');
      const subagentPath = join(subagentDir, 'subagent-session-001.jsonl');
      writeFileSync(
        subagentPath,
        [
          JSON.stringify({
            kind: 'subagent',
            sessionId: 'subagent-session-001',
            projectHash: 'hash-001',
            startTime: '2026-06-22T01:00:00.000Z',
            lastUpdated: '2026-06-22T01:00:00.000Z',
          }),
          JSON.stringify({
            id: 'm1',
            timestamp: '2026-06-22T01:00:01.000Z',
            type: 'user',
            content: [{ text: 'subagent task' }],
          }),
          JSON.stringify({
            id: 'm2',
            timestamp: '2026-06-22T01:00:02.000Z',
            type: 'gemini',
            content: 'subagent answer',
          }),
          '',
        ].join('\n'),
      );

      const adapter = new GeminiCliAdapter(
        join(tmp, 'tmp'),
        join(tmp, 'no.json'),
      );
      const files: string[] = [];
      for await (const file of adapter.listSessionFiles()) files.push(file);
      expect(files).toEqual([subagentPath]);

      const info = await adapter.parseSessionInfo(subagentPath);
      expect(info).toMatchObject({
        id: 'subagent-session-001',
        agentRole: 'subagent',
        parentSessionId: 'parent-session-001',
        project: 'hash-001',
        cwd: '/Users/test/gemini',
        messageCount: 2,
      });
    } finally {
      rmSync(tmp, { recursive: true, force: true });
    }
  });

  it('resolveProject returns cwd for projectName', async () => {
    const cwd = await adapter.resolveProject('my-project');
    expect(cwd).toBe('/Users/test/my-project');
  });

  it('refreshes project cache when projects.json changes', async () => {
    const tmp = mkdtempSync(join(tmpdir(), 'engram-gemini-project-cache-'));
    try {
      const projectsFile = join(tmp, 'projects.json');
      writeFileSync(
        projectsFile,
        JSON.stringify({
          projects: {
            '/Users/test/old-project': 'my-project',
          },
        }),
      );
      const adapter = new GeminiCliAdapter(tmp, projectsFile);

      await expect(adapter.resolveProject('my-project')).resolves.toBe(
        '/Users/test/old-project',
      );

      writeFileSync(
        projectsFile,
        JSON.stringify({
          projects: {
            '/Users/test/new-project-renamed': 'my-project',
          },
        }),
      );
      const future = new Date(Date.now() + 10_000);
      utimesSync(projectsFile, future, future);

      await expect(adapter.resolveProject('my-project')).resolves.toBe(
        '/Users/test/new-project-renamed',
      );
    } finally {
      rmSync(tmp, { recursive: true, force: true });
    }
  });

  it('refreshes project cache when same-size rewrite preserves mtime', async () => {
    const tmp = mkdtempSync(join(tmpdir(), 'engram-gemini-project-ctime-'));
    try {
      const projectsFile = join(tmp, 'projects.json');
      const oldPayload = JSON.stringify({
        projects: {
          '/Users/test/aaa-project': 'my-project',
        },
      });
      const newPayload = JSON.stringify({
        projects: {
          '/Users/test/bbb-project': 'my-project',
        },
      });
      expect(newPayload.length).toBe(oldPayload.length);
      writeFileSync(projectsFile, oldPayload);
      const originalTimes = statSync(projectsFile);
      const adapter = new GeminiCliAdapter(tmp, projectsFile);

      await expect(adapter.resolveProject('my-project')).resolves.toBe(
        '/Users/test/aaa-project',
      );

      writeFileSync(projectsFile, newPayload);
      utimesSync(projectsFile, originalTimes.atime, originalTimes.mtime);

      await expect(adapter.resolveProject('my-project')).resolves.toBe(
        '/Users/test/bbb-project',
      );
    } finally {
      rmSync(tmp, { recursive: true, force: true });
    }
  });

  it('keys project cache signature with ctime as well as size and mtime', () => {
    const source = readFileSync(
      join(__dirname, '../../src/adapters/gemini-cli.ts'),
      'utf8',
    );

    expect(source).toContain('fileStat.size');
    expect(source).toContain('fileStat.mtimeMs');
    expect(source).toContain('fileStat.ctimeMs');
  });

  it('skips oversized session JSON files before reading them', async () => {
    const tmp = mkdtempSync(join(tmpdir(), 'engram-gemini-large-'));
    try {
      const largeSession = join(tmp, 'session-large.json');
      writeFileSync(
        largeSession,
        JSON.stringify({
          sessionId: 'large',
          projectHash: 'h',
          startTime: '2026-01-25T14:00:00.000Z',
          messages: [],
          padding: 'x'.repeat(11 * 1024 * 1024),
        }),
      );
      const adapter = new GeminiCliAdapter(tmp, join(tmp, 'projects.json'));

      await expect(adapter.parseSessionInfo(largeSession)).resolves.toBeNull();
    } finally {
      rmSync(tmp, { recursive: true, force: true });
    }
  });

  it('ignores oversized sidecar files before reading them', async () => {
    const tmp = mkdtempSync(join(tmpdir(), 'engram-gemini-large-sidecar-'));
    try {
      const sessionId = 'g-large-sidecar';
      const sessionPath = join(tmp, `session-${sessionId}.json`);
      writeFileSync(
        sessionPath,
        JSON.stringify({
          sessionId,
          projectHash: 'h',
          startTime: '2026-01-25T14:00:00.000Z',
          messages: [
            {
              id: '1',
              timestamp: '2026-01-25T14:00:00.000Z',
              type: 'user',
              content: 'hi',
            },
          ],
        }),
      );
      writeFileSync(
        join(tmp, `${sessionId}.engram.json`),
        JSON.stringify({
          originator: 'Claude Code',
          padding: 'x'.repeat(11 * 1024 * 1024),
        }),
      );
      const adapter = new GeminiCliAdapter(tmp, join(tmp, 'projects.json'));

      const info = await adapter.parseSessionInfo(sessionPath);

      expect(info?.id).toBe(sessionId);
      expect(info?.originator).toBeUndefined();
      expect(info?.agentRole).toBeUndefined();
    } finally {
      rmSync(tmp, { recursive: true, force: true });
    }
  });

  it('ignores oversized projects.json before reading it', async () => {
    const tmp = mkdtempSync(join(tmpdir(), 'engram-gemini-large-projects-'));
    try {
      const projectsFile = join(tmp, 'projects.json');
      writeFileSync(
        projectsFile,
        JSON.stringify({
          projects: {
            '/Users/test/my-project': 'my-project',
          },
          padding: 'x'.repeat(11 * 1024 * 1024),
        }),
      );
      const adapter = new GeminiCliAdapter(tmp, projectsFile);

      await expect(adapter.resolveProject('my-project')).resolves.toBeNull();
    } finally {
      rmSync(tmp, { recursive: true, force: true });
    }
  });
});

describe('GeminiCliAdapter sidecar originator (R5-31)', () => {
  let tmp: string;
  afterEach(() => {
    if (tmp) rmSync(tmp, { recursive: true, force: true });
  });

  function writeSession(originator: string): string {
    tmp = mkdtempSync(join(tmpdir(), 'engram-gemini-orig-'));
    const sessionId = 'g-orig-001';
    const sessionPath = join(tmp, `session-${sessionId}.json`);
    const session = {
      sessionId,
      projectHash: 'h',
      startTime: '2026-01-25T14:00:00.000Z',
      messages: [
        {
          id: '1',
          timestamp: '2026-01-25T14:00:00.000Z',
          type: 'user',
          content: 'hi',
        },
      ],
    };
    writeFileSync(sessionPath, JSON.stringify(session));
    writeFileSync(
      join(tmp, `${sessionId}.engram.json`),
      JSON.stringify({ originator }),
    );
    return sessionPath;
  }

  it('classifies the slug form "claude-code" as dispatched', async () => {
    const adapter = new GeminiCliAdapter(tmpdir(), join(tmpdir(), 'no.json'));
    const info = await adapter.parseSessionInfo(writeSession('claude-code'));
    expect(info?.agentRole).toBe('dispatched');
  });

  it('classifies the Codex form "Claude Code" as dispatched', async () => {
    const adapter = new GeminiCliAdapter(tmpdir(), join(tmpdir(), 'no.json'));
    const info = await adapter.parseSessionInfo(writeSession('Claude Code'));
    expect(info?.agentRole).toBe('dispatched');
  });

  it('does not classify an unrelated originator as dispatched', async () => {
    const adapter = new GeminiCliAdapter(tmpdir(), join(tmpdir(), 'no.json'));
    const info = await adapter.parseSessionInfo(writeSession('vscode'));
    expect(info?.agentRole).toBeUndefined();
  });
});
