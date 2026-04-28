import { mkdirSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { KimiAdapter } from '../../src/adapters/kimi.js';

const __dirname = dirname(fileURLToPath(import.meta.url));
const FIXTURE_ROOT = join(__dirname, '../fixtures/kimi');
const FIXTURE_SESSIONS = join(FIXTURE_ROOT, 'sessions');
const FIXTURE_KIMI_JSON = join(FIXTURE_ROOT, 'kimi.json');
const FIXTURE_CONTEXT = join(FIXTURE_SESSIONS, 'ws-001/sess-001/context.jsonl');

describe('KimiAdapter', () => {
  const adapter = new KimiAdapter(FIXTURE_SESSIONS, FIXTURE_KIMI_JSON);

  it('name is kimi', () => {
    expect(adapter.name).toBe('kimi');
  });

  it('listSessionFiles yields context.jsonl paths', async () => {
    const files: string[] = [];
    for await (const f of adapter.listSessionFiles()) files.push(f);
    expect(files).toHaveLength(1);
    expect(files[0]).toContain('context.jsonl');
  });

  it('parseSessionInfo extracts metadata', async () => {
    const info = await adapter.parseSessionInfo(FIXTURE_CONTEXT);
    expect(info).not.toBeNull();
    expect(info?.id).toBe('sess-001');
    expect(info?.source).toBe('kimi');
    expect(info?.cwd).toBe('/Users/test/my-project');
    expect(info?.userMessageCount).toBe(2);
    expect(info?.summary).toBe('帮我排查内存泄漏');
  });

  it('streamMessages skips checkpoints', async () => {
    const messages = [];
    for await (const msg of adapter.streamMessages(FIXTURE_CONTEXT))
      messages.push(msg);
    expect(
      messages.every((m) => m.role === 'user' || m.role === 'assistant'),
    ).toBe(true);
    expect(messages[0].content).toBe('帮我排查内存泄漏');
    expect(messages[1].role).toBe('assistant');
  });

  it('streamMessages aligns user msg with wire TurnBegin and assistant with TurnEnd', async () => {
    const messages = [];
    for await (const msg of adapter.streamMessages(FIXTURE_CONTEXT))
      messages.push(msg);
    // wire.jsonl has TurnBegin@1770000001 (user) + TurnEnd@1770000060 (assistant)
    const firstUser = messages.find((m) => m.role === 'user');
    const firstAsst = messages.find((m) => m.role === 'assistant');
    expect(firstUser?.timestamp).toBe('2026-02-02T02:40:01.000Z');
    expect(firstAsst?.timestamp).toBe('2026-02-02T02:41:00.000Z');
  });

  describe('turn-pair robustness when a TurnEnd is missing', () => {
    const tmpRoot = join(tmpdir(), `engram-kimi-turns-${Date.now()}`);
    const sessionsRoot = join(tmpRoot, 'sessions');
    const sessDir = join(sessionsRoot, 'ws-x', 'sess-y');
    const ctxPath = join(sessDir, 'context.jsonl');
    const wirePath = join(sessDir, 'wire.jsonl');

    beforeAll(() => {
      mkdirSync(sessDir, { recursive: true });
      writeFileSync(
        ctxPath,
        [
          '{"role":"_checkpoint","id":0}',
          '{"role":"user","content":"q1"}',
          '{"role":"assistant","content":"a1"}',
          '{"role":"user","content":"q2"}',
          '{"role":"assistant","content":"a2"}',
        ].join('\n'),
      );
      // turn 1: TurnBegin@10, TurnEnd@20
      // turn 2: TurnBegin@30 (NO TurnEnd — simulates incomplete session)
      writeFileSync(
        wirePath,
        [
          '{"timestamp":1770000010,"message":{"type":"TurnBegin"}}',
          '{"timestamp":1770000020,"message":{"type":"TurnEnd"}}',
          '{"timestamp":1770000030,"message":{"type":"TurnBegin"}}',
        ].join('\n'),
      );
    });

    afterAll(() => rmSync(tmpRoot, { recursive: true, force: true }));

    it('turn 2 assistant falls back to its own begin, not turn 1 end', async () => {
      const a = new KimiAdapter(sessionsRoot, FIXTURE_KIMI_JSON);
      const messages = [];
      for await (const msg of a.streamMessages(ctxPath)) messages.push(msg);
      const users = messages.filter((m) => m.role === 'user');
      const assts = messages.filter((m) => m.role === 'assistant');
      // turn 1 begin = 1770000010 → 2026-02-02T02:40:10.000Z
      expect(users[0].timestamp).toBe('2026-02-02T02:40:10.000Z');
      // turn 1 end = 1770000020 → 2026-02-02T02:40:20.000Z
      expect(assts[0].timestamp).toBe('2026-02-02T02:40:20.000Z');
      // turn 2 begin = 1770000030 → user2 ts; assistant2 has no TurnEnd, must
      // fall back to turn 2's begin (NOT to turn 1's end at 02:40:20).
      expect(users[1].timestamp).toBe('2026-02-02T02:40:30.000Z');
      expect(assts[1].timestamp).toBe('2026-02-02T02:40:30.000Z');
    });
  });
});
