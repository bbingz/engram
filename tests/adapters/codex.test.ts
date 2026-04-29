// tests/adapters/codex.test.ts

import { mkdirSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { CodexAdapter } from '../../src/adapters/codex.js';

const __dirname = dirname(fileURLToPath(import.meta.url));
const FIXTURE = join(__dirname, '../fixtures/codex/sample.jsonl');
const DRIFT_FIXTURE = join(__dirname, '../fixtures/codex/schema_drift.jsonl');

describe('CodexAdapter', () => {
  const adapter = new CodexAdapter();

  it('name is codex', () => {
    expect(adapter.name).toBe('codex');
  });

  it('parseSessionInfo extracts metadata', async () => {
    const info = await adapter.parseSessionInfo(FIXTURE);
    expect(info).not.toBeNull();
    expect(info?.id).toBe('codex-session-001');
    expect(info?.source).toBe('codex');
    expect(info?.cwd).toBe('/Users/test/my-project');
    expect(info?.startTime).toBe('2026-01-15T10:00:00.000Z');
    expect(info?.userMessageCount).toBe(2);
    expect(info?.summary).toBe('帮我修复登录 bug，用户无法登录');
  });

  it('counts function_call / function_call_output as tool messages', async () => {
    const info = await adapter.parseSessionInfo(FIXTURE);
    expect(info?.toolMessageCount).toBe(2);
    expect(info?.messageCount).toBe(
      (info?.userMessageCount ?? 0) +
        (info?.assistantMessageCount ?? 0) +
        (info?.toolMessageCount ?? 0),
    );
  });

  it('endTime tracks the last timestamped line, not the last user message', async () => {
    const info = await adapter.parseSessionInfo(FIXTURE);
    expect(info?.endTime).toBe('2026-01-15T10:05:00.000Z');
  });

  it('falls back to model_provider when response_item.payload.model is absent', async () => {
    const info = await adapter.parseSessionInfo(FIXTURE);
    expect(info?.model).toBe('openai');
  });

  it('prefers response_item.payload.model over session_meta.model_provider', async () => {
    const info = await adapter.parseSessionInfo(DRIFT_FIXTURE);
    expect(info?.model).toBe('gpt-4.1');
  });

  it('streamMessages yields user and assistant messages', async () => {
    const messages = [];
    for await (const msg of adapter.streamMessages(FIXTURE)) {
      messages.push(msg);
    }
    expect(messages.length).toBeGreaterThanOrEqual(3);
    expect(messages[0].role).toBe('user');
    expect(messages[0].content).toBe('帮我修复登录 bug，用户无法登录');
    expect(messages[1].role).toBe('assistant');
  });

  it('streamMessages yields tool role for function_call and function_call_output', async () => {
    const messages = [];
    for await (const msg of adapter.streamMessages(FIXTURE)) {
      messages.push(msg);
    }
    const tools = messages.filter((m) => m.role === 'tool');
    expect(tools).toHaveLength(2);
    expect(tools[0].toolCalls?.[0]?.name).toBe('read_file');
    expect(tools[0].toolCalls?.[0]?.input).toContain('src/auth.ts');
    expect(tools[1].content).toBe('// auth.ts content...');
  });

  it('maps assistant payload.usage onto Message.usage', async () => {
    const messages = [];
    for await (const msg of adapter.streamMessages(DRIFT_FIXTURE)) {
      messages.push(msg);
    }
    const assistant = messages.find((m) => m.role === 'assistant');
    expect(assistant?.usage).toBeDefined();
    expect(assistant?.usage?.inputTokens).toBe(50);
    expect(assistant?.usage?.outputTokens).toBe(30);
  });

  it('streamMessages respects offset and limit', async () => {
    const messages = [];
    for await (const msg of adapter.streamMessages(FIXTURE, {
      offset: 1,
      limit: 1,
    })) {
      messages.push(msg);
    }
    expect(messages).toHaveLength(1);
    expect(messages[0].role).toBe('assistant');
  });

  it('lists rollout files from archived_sessions next to sessions', async () => {
    const tmpRoot = join(tmpdir(), `engram-codex-archive-${Date.now()}`);
    const sessionsDir = join(tmpRoot, 'sessions');
    const archivedDir = join(tmpRoot, 'archived_sessions');
    const activePath = join(sessionsDir, '2026/04/29/rollout-active.jsonl');
    const archivedPath = join(archivedDir, 'rollout-archived.jsonl');
    mkdirSync(dirname(activePath), { recursive: true });
    mkdirSync(archivedDir, { recursive: true });
    const fixture = (id: string) =>
      [
        JSON.stringify({
          timestamp: '2026-04-29T00:00:00.000Z',
          type: 'session_meta',
          payload: {
            id,
            timestamp: '2026-04-29T00:00:00.000Z',
            cwd: '/repo',
            originator: 'Codex Desktop',
            model_provider: 'openai',
          },
        }),
        JSON.stringify({
          timestamp: '2026-04-29T00:00:01.000Z',
          type: 'response_item',
          payload: {
            type: 'message',
            role: 'user',
            content: [{ type: 'input_text', text: 'hello' }],
          },
        }),
      ].join('\n');
    writeFileSync(activePath, `${fixture('active')}\n`);
    writeFileSync(archivedPath, `${fixture('archived')}\n`);

    const archiveAdapter = new CodexAdapter(sessionsDir);
    const files = [];
    try {
      for await (const file of archiveAdapter.listSessionFiles()) {
        files.push(file);
      }
    } finally {
      rmSync(tmpRoot, { recursive: true, force: true });
    }

    expect(files.sort()).toEqual([archivedPath, activePath].sort());
  });

  describe('function_call edge cases', () => {
    const tmpRoot = join(tmpdir(), `engram-codex-fc-${Date.now()}`);
    const fcPath = join(tmpRoot, 'rollout-fc.jsonl');

    beforeAll(() => {
      mkdirSync(tmpRoot, { recursive: true });
      const lines = [
        // session_meta
        JSON.stringify({
          timestamp: '2026-01-15T10:00:00.000Z',
          type: 'session_meta',
          payload: {
            id: 'fc-edge',
            timestamp: '2026-01-15T10:00:00.000Z',
            cwd: '/x',
            model_provider: 'openai',
          },
        }),
        // user
        JSON.stringify({
          timestamp: '2026-01-15T10:00:01.000Z',
          type: 'response_item',
          payload: {
            type: 'message',
            role: 'user',
            content: [{ type: 'input_text', text: 'go' }],
          },
        }),
        // function_call with no arguments and empty name
        JSON.stringify({
          timestamp: '2026-01-15T10:00:02.000Z',
          type: 'response_item',
          payload: { type: 'function_call' },
        }),
        // orphan function_call_output (no preceding call)
        JSON.stringify({
          timestamp: '2026-01-15T10:00:03.000Z',
          type: 'response_item',
          payload: {
            type: 'function_call_output',
            output: 'orphan-out',
          },
        }),
        // function_call with pre-serialized arguments string
        JSON.stringify({
          timestamp: '2026-01-15T10:00:04.000Z',
          type: 'response_item',
          payload: {
            type: 'function_call',
            name: 'shell',
            arguments: '{"cmd":"ls"}',
          },
        }),
      ];
      writeFileSync(fcPath, `${lines.join('\n')}\n`);
    });

    afterAll(() => rmSync(tmpRoot, { recursive: true, force: true }));

    it('handles missing arguments + empty tool name without throwing', async () => {
      const messages = [];
      for await (const m of adapter.streamMessages(fcPath)) messages.push(m);
      const tools = messages.filter((m) => m.role === 'tool');
      expect(tools.length).toBe(3);
      // First tool entry: empty name + no arguments → name == '', input undefined
      expect(tools[0].toolCalls?.[0]?.name).toBe('');
      expect(tools[0].toolCalls?.[0]?.input).toBeUndefined();
    });

    it('streams orphan function_call_output as a tool message', async () => {
      const messages = [];
      for await (const m of adapter.streamMessages(fcPath)) messages.push(m);
      const orphan = messages.find((m) => m.content === 'orphan-out');
      expect(orphan?.role).toBe('tool');
    });

    it('preserves pre-serialized string arguments instead of double-encoding', async () => {
      const messages = [];
      for await (const m of adapter.streamMessages(fcPath)) messages.push(m);
      // String args are passed through JSON.stringify → wrapped in quotes.
      // Document the current behavior so a future change is intentional.
      const shellCall = messages.find(
        (m) => m.toolCalls?.[0]?.name === 'shell',
      );
      expect(shellCall?.toolCalls?.[0]?.input).toBe('"{\\"cmd\\":\\"ls\\"}"');
    });

    it('counts every function_call / function_call_output as a tool message', async () => {
      const info = await adapter.parseSessionInfo(fcPath);
      expect(info?.toolMessageCount).toBe(3);
    });

    it('offset/limit treat tool messages the same as user/assistant', async () => {
      const all = [];
      for await (const m of adapter.streamMessages(fcPath)) all.push(m);
      // user + 3 tools → offset=1, limit=2 → tools[0], tools[1]
      const sliced = [];
      for await (const m of adapter.streamMessages(fcPath, {
        offset: 1,
        limit: 2,
      }))
        sliced.push(m);
      expect(sliced).toHaveLength(2);
      expect(sliced[0]).toEqual(all[1]);
      expect(sliced[1]).toEqual(all[2]);
    });
  });

  describe('repeated function_call / function_call_output records', () => {
    const tmpRoot = join(tmpdir(), `engram-codex-dup-${Date.now()}`);
    const dupPath = join(tmpRoot, 'rollout-dup.jsonl');

    beforeAll(() => {
      mkdirSync(tmpRoot, { recursive: true });
      writeFileSync(
        dupPath,
        [
          JSON.stringify({
            timestamp: '2026-01-15T10:00:00.000Z',
            type: 'session_meta',
            payload: {
              id: 'dup',
              timestamp: '2026-01-15T10:00:00.000Z',
              cwd: '/x',
              model_provider: 'openai',
            },
          }),
          // Same call_id appears twice (e.g. retry), each with its output
          JSON.stringify({
            timestamp: '2026-01-15T10:00:01.000Z',
            type: 'response_item',
            payload: {
              type: 'function_call',
              name: 'shell',
              call_id: 'c1',
              arguments: { cmd: 'ls' },
            },
          }),
          JSON.stringify({
            timestamp: '2026-01-15T10:00:02.000Z',
            type: 'response_item',
            payload: {
              type: 'function_call_output',
              call_id: 'c1',
              output: 'r1',
            },
          }),
          JSON.stringify({
            timestamp: '2026-01-15T10:00:03.000Z',
            type: 'response_item',
            payload: {
              type: 'function_call',
              name: 'shell',
              call_id: 'c1',
              arguments: { cmd: 'ls' },
            },
          }),
          JSON.stringify({
            timestamp: '2026-01-15T10:00:04.000Z',
            type: 'response_item',
            payload: {
              type: 'function_call_output',
              call_id: 'c1',
              output: 'r2',
            },
          }),
        ].join('\n'),
      );
    });

    afterAll(() => rmSync(tmpRoot, { recursive: true, force: true }));

    it('counts and emits each repeated call/output independently (no dedup)', async () => {
      const info = await adapter.parseSessionInfo(dupPath);
      expect(info?.toolMessageCount).toBe(4);

      const messages = [];
      for await (const m of adapter.streamMessages(dupPath)) messages.push(m);
      const tools = messages.filter((m) => m.role === 'tool');
      expect(tools).toHaveLength(4);
      // Outputs surface in order, both retries preserved
      const outputs = tools.filter((t) => !t.toolCalls).map((t) => t.content);
      expect(outputs).toEqual(['r1', 'r2']);
    });
  });
});
