// tests/adapters/gemini-cli.test.ts

import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
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

  it('resolveProject returns cwd for projectName', async () => {
    const cwd = await adapter.resolveProject('my-project');
    expect(cwd).toBe('/Users/test/my-project');
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
