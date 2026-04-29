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

  describe('same-role-consecutive sequences', () => {
    const tmpRoot = join(tmpdir(), `engram-kimi-consec-${Date.now()}`);
    const sessionsRoot = join(tmpRoot, 'sessions');

    function makeSession(name: string, contextLines: string[]): string {
      const sessDir = join(sessionsRoot, 'ws', name);
      mkdirSync(sessDir, { recursive: true });
      writeFileSync(join(sessDir, 'context.jsonl'), contextLines.join('\n'));
      // 3 wire turns: 10/20, 30/40, 50/60
      writeFileSync(
        join(sessDir, 'wire.jsonl'),
        [
          '{"timestamp":1770000010,"message":{"type":"TurnBegin"}}',
          '{"timestamp":1770000020,"message":{"type":"TurnEnd"}}',
          '{"timestamp":1770000030,"message":{"type":"TurnBegin"}}',
          '{"timestamp":1770000040,"message":{"type":"TurnEnd"}}',
          '{"timestamp":1770000050,"message":{"type":"TurnBegin"}}',
          '{"timestamp":1770000060,"message":{"type":"TurnEnd"}}',
        ].join('\n'),
      );
      return join(sessDir, 'context.jsonl');
    }

    afterAll(() => rmSync(tmpRoot, { recursive: true, force: true }));

    it('user→user advances to next turn (second user binds turn[1].begin)', async () => {
      const ctx = makeSession('uu-a', [
        '{"role":"user","content":"q1"}',
        '{"role":"user","content":"q1b"}',
        '{"role":"assistant","content":"a"}',
      ]);
      const a = new KimiAdapter(sessionsRoot, FIXTURE_KIMI_JSON);
      const msgs = [];
      for await (const m of a.streamMessages(ctx)) msgs.push(m);
      expect(msgs[0].timestamp).toBe('2026-02-02T02:40:10.000Z'); // turn0 begin
      expect(msgs[1].timestamp).toBe('2026-02-02T02:40:30.000Z'); // turn1 begin
      // assistant binds turn[1].end (not turn[1].end which would skip turn1's existence)
      expect(msgs[2].timestamp).toBe('2026-02-02T02:40:40.000Z'); // turn1 end
    });

    it('assistant→assistant advances to next turn (second asst binds turn[1].end)', async () => {
      const ctx = makeSession('u-aa', [
        '{"role":"user","content":"q"}',
        '{"role":"assistant","content":"a1"}',
        '{"role":"assistant","content":"a2"}',
      ]);
      const a = new KimiAdapter(sessionsRoot, FIXTURE_KIMI_JSON);
      const msgs = [];
      for await (const m of a.streamMessages(ctx)) msgs.push(m);
      expect(msgs[0].timestamp).toBe('2026-02-02T02:40:10.000Z'); // turn0 begin
      expect(msgs[1].timestamp).toBe('2026-02-02T02:40:20.000Z'); // turn0 end
      expect(msgs[2].timestamp).toBe('2026-02-02T02:40:40.000Z'); // turn1 end
    });

    it('mixed u-a-a-u stays correctly aligned across the consecutive-asst boundary', async () => {
      const ctx = makeSession('uaau', [
        '{"role":"user","content":"q1"}',
        '{"role":"assistant","content":"a1"}',
        '{"role":"assistant","content":"a1b"}',
        '{"role":"user","content":"q2"}',
        '{"role":"assistant","content":"a2"}',
      ]);
      const a = new KimiAdapter(sessionsRoot, FIXTURE_KIMI_JSON);
      const msgs = [];
      for await (const m of a.streamMessages(ctx)) msgs.push(m);
      // turn0: begin=10, end=20
      // turn1: begin=30, end=40 (asst-after-asst pushes here)
      // turn2: begin=50, end=60 (next user pushes here)
      expect(msgs[0].timestamp).toBe('2026-02-02T02:40:10.000Z');
      expect(msgs[1].timestamp).toBe('2026-02-02T02:40:20.000Z');
      expect(msgs[2].timestamp).toBe('2026-02-02T02:40:40.000Z');
      expect(msgs[3].timestamp).toBe('2026-02-02T02:40:50.000Z');
      expect(msgs[4].timestamp).toBe('2026-02-02T02:41:00.000Z');
    });
  });

  describe('no wire.jsonl — fall back to context line timestamps', () => {
    const tmpRoot = join(tmpdir(), `engram-kimi-nowire-${Date.now()}`);
    const sessionsRoot = join(tmpRoot, 'sessions');
    const sessDir = join(sessionsRoot, 'ws-z', 'sess-no-wire');
    const ctxPath = join(sessDir, 'context.jsonl');

    beforeAll(() => {
      mkdirSync(sessDir, { recursive: true });
      writeFileSync(
        ctxPath,
        [
          // mix of numeric and ISO-string timestamps to cover both branches
          '{"role":"user","content":"q","timestamp":1770000100}',
          '{"role":"assistant","content":"a","timestamp":"2026-02-02T02:42:00.000Z"}',
        ].join('\n'),
      );
    });

    afterAll(() => rmSync(tmpRoot, { recursive: true, force: true }));

    it('parseSessionInfo uses line timestamps when wire.jsonl is absent', async () => {
      const a = new KimiAdapter(sessionsRoot, FIXTURE_KIMI_JSON);
      const info = await a.parseSessionInfo(ctxPath);
      // First line ts is numeric epoch seconds → 1770000100 = 02:41:40Z
      expect(info?.startTime).toBe('2026-02-02T02:41:40.000Z');
      // Last line ts is the ISO string, passed through verbatim
      expect(info?.endTime).toBe('2026-02-02T02:42:00.000Z');
    });

    it('streamMessages emits per-line timestamps for both numeric and string', async () => {
      const a = new KimiAdapter(sessionsRoot, FIXTURE_KIMI_JSON);
      const msgs = [];
      for await (const m of a.streamMessages(ctxPath)) msgs.push(m);
      expect(msgs[0].timestamp).toBe('2026-02-02T02:41:40.000Z');
      expect(msgs[1].timestamp).toBe('2026-02-02T02:42:00.000Z');
    });
  });
});
