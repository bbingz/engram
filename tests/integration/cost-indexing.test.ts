import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { beforeAll, describe, expect, it } from 'vitest';
import { ClaudeCodeAdapter } from '../../src/adapters/claude-code.js';
import type { Message, SessionAdapter } from '../../src/adapters/types.js';
import { Database } from '../../src/core/db.js';
import { Indexer } from '../../src/core/indexer.js';

const __dirname = dirname(fileURLToPath(import.meta.url));
const FIXTURE = resolve(
  __dirname,
  '../fixtures/claude-code/session-with-usage.jsonl',
);

describe('cost indexing integration', () => {
  let db: Database;
  const adapter = new ClaudeCodeAdapter();

  beforeAll(async () => {
    db = new Database(':memory:');

    // Parse and index the fixture
    const info = await adapter.parseSessionInfo(FIXTURE);
    expect(info).toBeDefined();

    // Insert session
    db.getRawDb()
      .prepare(
        `INSERT INTO sessions (id, source, start_time, cwd, project, model, message_count, user_message_count, assistant_message_count, tool_message_count, system_message_count, file_path, size_bytes, tier) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
      )
      .run(
        info?.id,
        info?.source,
        info?.startTime,
        info?.cwd,
        info?.project || '',
        info?.model || '',
        info?.messageCount,
        info?.userMessageCount,
        info?.assistantMessageCount,
        info?.toolMessageCount,
        info?.systemMessageCount,
        FIXTURE,
        info?.sizeBytes,
        'normal',
      );

    // Stream messages and accumulate
    let inputTokens = 0,
      outputTokens = 0,
      cacheRead = 0,
      cacheCreate = 0;
    const toolCounts = new Map<string, number>();
    for await (const msg of adapter.streamMessages(FIXTURE)) {
      if (msg.usage) {
        inputTokens += msg.usage.inputTokens;
        outputTokens += msg.usage.outputTokens;
        cacheRead += msg.usage.cacheReadTokens ?? 0;
        cacheCreate += msg.usage.cacheCreationTokens ?? 0;
      }
      if (msg.toolCalls) {
        for (const tc of msg.toolCalls) {
          toolCounts.set(tc.name, (toolCounts.get(tc.name) || 0) + 1);
        }
      }
    }

    // Write extracted data
    if (inputTokens > 0) {
      const { computeCost } = await import('../../src/core/pricing.js');
      const cost = computeCost(
        info?.model || '',
        inputTokens,
        outputTokens,
        cacheRead,
        cacheCreate,
      );
      db.upsertSessionCost(
        info?.id,
        info?.model || '',
        inputTokens,
        outputTokens,
        cacheRead,
        cacheCreate,
        cost,
      );
    }
    if (toolCounts.size > 0) {
      db.upsertSessionTools(info?.id, toolCounts);
    }
  });

  it('stores token costs in session_costs', () => {
    const costs = db.getCostsSummary({});
    expect(costs.length).toBe(1);
    expect(costs[0].inputTokens).toBe(3500); // 1500 + 2000
    expect(costs[0].outputTokens).toBe(150); // 50 + 100
    expect(costs[0].costUsd).toBeGreaterThan(0);
  });

  it('stores tool calls in session_tools', () => {
    const tools = db.getToolAnalytics({});
    expect(tools.length).toBe(2); // Read + Edit
    const readTool = tools.find((t: any) => t.key === 'Read');
    expect(readTool).toBeDefined();
    expect(readTool.callCount).toBe(1);
    const editTool = tools.find((t: any) => t.key === 'Edit');
    expect(editTool).toBeDefined();
    expect(editTool.callCount).toBe(1);
  });

  it('computes cost correctly for claude-sonnet-4-6', () => {
    const costs = db.getCostsSummary({});
    // claude-sonnet-4-6: input=$3/M, output=$15/M, cacheRead=$0.3/M, cacheWrite=$3.75/M
    // input: 3500/1M * 3 = 0.0105
    // output: 150/1M * 15 = 0.00225
    // cacheRead: 2300/1M * 0.3 = 0.00069
    // cacheWrite: 1000/1M * 3.75 = 0.00375
    // total = 0.01719
    expect(costs[0].costUsd).toBeCloseTo(0.017, 2);
  });
});

describe('backfill termination', () => {
  it('backfillCosts terminates for sessions without usage data (no infinite loop)', async () => {
    const db = new Database(':memory:');

    // Insert two sessions: one claude-code (has usage), one codex (no usage data)
    db.getRawDb().exec(
      `INSERT INTO sessions (id, source, start_time, cwd, project, model, message_count, user_message_count, assistant_message_count, tool_message_count, system_message_count, file_path, size_bytes, tier) VALUES ('cc1', 'claude-code', '2026-03-20T10:00:00Z', '/test', 'proj', 'claude-sonnet-4-6', 5, 2, 2, 0, 1, '/test/cc1.jsonl', 500, 'normal')`,
    );
    db.getRawDb().exec(
      `INSERT INTO sessions (id, source, start_time, cwd, project, model, message_count, user_message_count, assistant_message_count, tool_message_count, system_message_count, file_path, size_bytes, tier) VALUES ('cx1', 'codex', '2026-03-20T11:00:00Z', '/test', 'proj', 'gpt-4', 3, 1, 1, 0, 1, '/test/cx1.jsonl', 300, 'normal')`,
    );

    // Both should appear in sessionsWithoutCosts
    expect(db.sessionsWithoutCosts().length).toBe(2);

    // Create a mock adapter that yields messages without usage
    const mockAdapter: SessionAdapter = {
      name: 'codex' as any,
      detect: async () => true,
      listSessionFiles: async function* () {},
      parseSessionInfo: async () => null,
      streamMessages: async function* (): AsyncGenerator<Message> {
        yield { role: 'user', content: 'hello' };
        yield { role: 'assistant', content: 'hi there' };
      },
    };
    const mockClaudeAdapter: SessionAdapter = {
      name: 'claude-code' as any,
      detect: async () => true,
      listSessionFiles: async function* () {},
      parseSessionInfo: async () => null,
      streamMessages: async function* (): AsyncGenerator<Message> {
        yield { role: 'user', content: 'hello' };
        yield {
          role: 'assistant',
          content: 'response',
          usage: { inputTokens: 100, outputTokens: 50 },
        };
      },
    };

    const indexer = new Indexer(db, [mockClaudeAdapter, mockAdapter]);
    const count = await indexer.backfillCosts();

    // Both sessions should have been processed
    expect(count).toBe(2);
    // No sessions left without costs (backfill terminated)
    expect(db.sessionsWithoutCosts().length).toBe(0);
    // The codex session should have a zero-cost row
    const costs = db
      .getRawDb()
      .prepare('SELECT * FROM session_costs WHERE session_id = ?')
      .get('cx1') as any;
    expect(costs).toBeDefined();
    expect(costs.input_tokens).toBe(0);
    expect(costs.cost_usd).toBe(0);

    db.close();
  });

  it('backfillCosts handles sessions with no adapter or missing filePath without looping', async () => {
    const db = new Database(':memory:');

    // Session with no matching adapter (source = 'unknown-tool')
    db.getRawDb().exec(
      `INSERT INTO sessions (id, source, start_time, cwd, project, model, message_count, user_message_count, assistant_message_count, tool_message_count, system_message_count, file_path, size_bytes, tier) VALUES ('no-adapter', 'unknown-tool', '2026-03-20T10:00:00Z', '/test', 'proj', 'some-model', 3, 1, 1, 0, 1, '/test/no-adapter.jsonl', 200, 'normal')`,
    );

    // Session with empty filePath (use 'lite' tier since sessionsWithoutCosts excludes 'skip')
    db.getRawDb().exec(
      `INSERT INTO sessions (id, source, start_time, cwd, project, model, message_count, user_message_count, assistant_message_count, tool_message_count, system_message_count, file_path, size_bytes, tier) VALUES ('no-filepath', 'claude-code', '2026-03-20T11:00:00Z', '/test', 'proj', 'claude-sonnet-4-6', 1, 0, 0, 0, 1, '', 0, 'lite')`,
    );

    // Session whose adapter throws during streamMessages
    db.getRawDb().exec(
      `INSERT INTO sessions (id, source, start_time, cwd, project, model, message_count, user_message_count, assistant_message_count, tool_message_count, system_message_count, file_path, size_bytes, tier) VALUES ('throws', 'claude-code', '2026-03-20T12:00:00Z', '/test', 'proj', 'claude-sonnet-4-6', 2, 1, 1, 0, 0, '/test/throws.jsonl', 100, 'normal')`,
    );

    expect(db.sessionsWithoutCosts().length).toBe(3);

    const mockClaudeAdapter: SessionAdapter = {
      name: 'claude-code' as any,
      detect: async () => true,
      listSessionFiles: async function* () {},
      parseSessionInfo: async () => null,
      streamMessages: async function* (
        filePath: string,
      ): AsyncGenerator<Message> {
        if (filePath === '/test/throws.jsonl')
          throw new Error('file not found');
        yield { role: 'user', content: 'hello' };
      },
    };

    const indexer = new Indexer(db, [mockClaudeAdapter]);
    const count = await indexer.backfillCosts();

    // All 3 sessions processed (zero-cost rows written for all)
    expect(count).toBe(3);
    expect(db.sessionsWithoutCosts().length).toBe(0);

    // no-adapter: zero-cost row with its model preserved
    const noAdapterCosts = db
      .getRawDb()
      .prepare('SELECT * FROM session_costs WHERE session_id = ?')
      .get('no-adapter') as any;
    expect(noAdapterCosts).toBeDefined();
    expect(noAdapterCosts.model).toBe('some-model');
    expect(noAdapterCosts.input_tokens).toBe(0);
    expect(noAdapterCosts.cost_usd).toBe(0);

    // no-filepath: zero-cost row with empty model
    const noFilepathCosts = db
      .getRawDb()
      .prepare('SELECT * FROM session_costs WHERE session_id = ?')
      .get('no-filepath') as any;
    expect(noFilepathCosts).toBeDefined();
    expect(noFilepathCosts.input_tokens).toBe(0);
    expect(noFilepathCosts.cost_usd).toBe(0);

    // throws: zero-cost row written via catch path
    const throwsCosts = db
      .getRawDb()
      .prepare('SELECT * FROM session_costs WHERE session_id = ?')
      .get('throws') as any;
    expect(throwsCosts).toBeDefined();
    expect(throwsCosts.model).toBe('claude-sonnet-4-6');
    expect(throwsCosts.input_tokens).toBe(0);
    expect(throwsCosts.cost_usd).toBe(0);

    db.close();
  });
});
