// tests/adapters/copilot.test.ts

import { mkdirSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { CopilotAdapter } from '../../src/adapters/copilot.js';

const __dirname = dirname(fileURLToPath(import.meta.url));
const FIXTURE_DIR = join(__dirname, '../fixtures/copilot/session-1');
const FIXTURE = join(FIXTURE_DIR, 'events.jsonl');

describe('CopilotAdapter', () => {
  const adapter = new CopilotAdapter(join(__dirname, '../fixtures/copilot'));

  it('name is copilot', () => {
    expect(adapter.name).toBe('copilot');
  });

  it('parseSessionInfo extracts metadata from fixture', async () => {
    const info = await adapter.parseSessionInfo(FIXTURE);
    expect(info).not.toBeNull();
    expect(info?.id).toBe('test-session-1');
    expect(info?.source).toBe('copilot');
    expect(info?.cwd).toBe('/tmp/test-project');
    expect(info?.startTime).toBe('2026-01-01T00:00:00Z');
    expect(info?.userMessageCount).toBe(1);
    expect(info?.assistantMessageCount).toBe(1);
  });

  it('streamMessages yields user and assistant messages', async () => {
    const messages = [];
    for await (const msg of adapter.streamMessages(FIXTURE)) {
      messages.push(msg);
    }
    expect(messages.length).toBeGreaterThanOrEqual(2);
    expect(messages[0].role).toBe('user');
    expect(messages[0].content).toBe('Help me fix the bug');
    expect(messages[1].role).toBe('assistant');
    expect(messages[1].content).toBe("I'll look into that.");
  });

  it('streamMessages with limit: 1 yields only 1 message', async () => {
    const messages = [];
    for await (const msg of adapter.streamMessages(FIXTURE, { limit: 1 })) {
      messages.push(msg);
    }
    expect(messages).toHaveLength(1);
    expect(messages[0].role).toBe('user');
  });

  it('attaches shutdown model metrics to the last assistant message', async () => {
    const tmpRoot = join(tmpdir(), `engram-copilot-usage-${Date.now()}`);
    const sessionDir = join(tmpRoot, 'session-with-usage');
    const eventsPath = join(sessionDir, 'events.jsonl');
    mkdirSync(sessionDir, { recursive: true });
    writeFileSync(
      join(sessionDir, 'workspace.yaml'),
      [
        'id: session-with-usage',
        'cwd: /tmp/copilot-usage-project',
        'created_at: 2026-01-01T00:00:00Z',
        'updated_at: 2026-01-01T00:05:00Z',
      ].join('\n'),
    );
    writeFileSync(
      eventsPath,
      [
        '{"type":"user.message","timestamp":"2026-01-01T00:01:00Z","data":{"content":"Check usage"}}',
        '{"type":"assistant.message","timestamp":"2026-01-01T00:02:00Z","data":{"content":"Usage checked."}}',
        '{"type":"session.shutdown","timestamp":"2026-01-01T00:05:00Z","data":{"modelMetrics":{"gpt-5.4":{"usage":{"inputTokens":1200,"outputTokens":80,"cacheReadTokens":900,"cacheWriteTokens":40}}}}}',
        '',
      ].join('\n'),
    );

    try {
      const a = new CopilotAdapter(tmpRoot);
      const messages = [];
      for await (const msg of a.streamMessages(eventsPath)) {
        messages.push(msg);
      }

      expect(messages.map((msg) => msg.role)).toEqual(['user', 'assistant']);
      expect(messages[0].usage).toBeUndefined();
      expect(messages[1].usage).toEqual({
        inputTokens: 1200,
        outputTokens: 80,
        cacheReadTokens: 900,
        cacheCreationTokens: 40,
      });
    } finally {
      rmSync(tmpRoot, { recursive: true, force: true });
    }
  });

  it('falls back to checkpoint index when events are missing', async () => {
    const tmpRoot = join(tmpdir(), `engram-copilot-checkpoint-${Date.now()}`);
    const sessionDir = join(tmpRoot, 'session-no-events');
    const checkpointsDir = join(sessionDir, 'checkpoints');
    const indexPath = join(checkpointsDir, 'index.md');
    mkdirSync(checkpointsDir, { recursive: true });
    writeFileSync(
      join(sessionDir, 'workspace.yaml'),
      [
        'id: session-no-events',
        'cwd: /tmp/copilot-project',
        'created_at: 2026-06-01T10:00:00.000Z',
        'updated_at: 2026-06-01T10:05:00.000Z',
      ].join('\n'),
    );
    writeFileSync(
      indexPath,
      [
        '# Checkpoint History',
        '',
        '| # | Title | File |',
        '|---|-------|------|',
        '| 1 | Initial production deploy audit | 001-initial-production-deploy.md |',
        '| 2 | Follow-up verifier and rollback notes | 002-follow-up-verifier.md |',
        '',
      ].join('\n'),
    );
    writeFileSync(
      join(checkpointsDir, '001-initial-production-deploy.md'),
      '<overview>\nProduction deploy reached smoke-test phase.\n</overview>\n',
    );
    writeFileSync(
      join(checkpointsDir, '002-follow-up-verifier.md'),
      '<work_done>\nRollback notes were captured.\n</work_done>\n',
    );

    try {
      const a = new CopilotAdapter(tmpRoot);
      const locators = [];
      for await (const locator of a.listSessionFiles()) {
        locators.push(locator);
      }
      expect(locators).toEqual([indexPath]);

      const info = await a.parseSessionInfo(indexPath);
      expect(info?.id).toBe('session-no-events');
      expect(info?.cwd).toBe('/tmp/copilot-project');
      expect(info?.messageCount).toBe(2);
      expect(info?.systemMessageCount).toBe(2);
      expect(info?.summary).toBe('Initial production deploy audit');

      const messages = [];
      for await (const msg of a.streamMessages(indexPath)) {
        messages.push(msg);
      }
      expect(messages.map((msg) => msg.role)).toEqual(['system', 'system']);
      expect(messages.map((msg) => msg.content)).toEqual([
        'Checkpoint 1: Initial production deploy audit\n\n<overview>\nProduction deploy reached smoke-test phase.\n</overview>',
        'Checkpoint 2: Follow-up verifier and rollback notes\n\n<work_done>\nRollback notes were captured.\n</work_done>',
      ]);
    } finally {
      rmSync(tmpRoot, { recursive: true, force: true });
    }
  });

  describe('YAML quoted values', () => {
    const tmpRoot = join(tmpdir(), `engram-copilot-yaml-${Date.now()}`);
    const sessionDir = join(tmpRoot, 'session-quoted');
    const eventsPath = join(sessionDir, 'events.jsonl');

    beforeAll(() => {
      mkdirSync(sessionDir, { recursive: true });
      writeFileSync(
        join(sessionDir, 'workspace.yaml'),
        [
          'id: "quoted-id"',
          'cwd: "/tmp/path with space"',
          "created_at: '2026-01-01T00:00:00Z'",
          'updated_at: 2026-01-01T00:05:00Z',
        ].join('\n'),
      );
      // Need a real user/assistant pair so parseSessionInfo doesn't bail on
      // totalCount === 0; we only care about the metadata under test.
      writeFileSync(
        eventsPath,
        [
          '{"type":"user.message","timestamp":"2026-01-01T00:01:00Z","data":{"content":"hi"}}',
          '{"type":"assistant.message","timestamp":"2026-01-01T00:02:00Z","data":{"content":"ok"}}',
          '',
        ].join('\n'),
      );
    });

    afterAll(() => rmSync(tmpRoot, { recursive: true, force: true }));

    it('strips matched quote pairs from cwd / id / timestamps', async () => {
      const a = new CopilotAdapter(tmpRoot);
      const info = await a.parseSessionInfo(eventsPath);
      expect(info?.id).toBe('quoted-id');
      expect(info?.cwd).toBe('/tmp/path with space');
      expect(info?.startTime).toBe('2026-01-01T00:00:00Z');
    });
  });
});
