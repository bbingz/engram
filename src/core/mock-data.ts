import { randomUUID } from 'node:crypto';
import type { Database } from './db.js';
import { computeCost } from './pricing.js';

export interface MockStats {
  sessions: number;
  tools: number;
  costUsd: number;
}

const MOCK_SOURCES = [
  { name: 'claude-code', weight: 0.4 },
  { name: 'codex', weight: 0.15 },
  { name: 'gemini-cli', weight: 0.1 },
  { name: 'cursor', weight: 0.1 },
  { name: 'iflow', weight: 0.08 },
  { name: 'qwen', weight: 0.07 },
  { name: 'kimi', weight: 0.05 },
  { name: 'cline', weight: 0.05 },
] as const;

const MOCK_PROJECTS = [
  'weather-api',
  'chat-app',
  'ml-pipeline',
  'docs-site',
  'infra-tools',
];

const MOCK_MODELS = [
  { name: 'claude-sonnet-4-6', weight: 0.5 },
  { name: 'claude-opus-4-6', weight: 0.2 },
  { name: 'gpt-4o', weight: 0.15 },
  { name: 'gemini-2.0-flash', weight: 0.15 },
] as const;

const MOCK_TIERS = [
  { name: 'normal', weight: 0.6 },
  { name: 'lite', weight: 0.2 },
  { name: 'premium', weight: 0.1 },
  { name: 'skip', weight: 0.1 },
] as const;

const MOCK_TOOLS = [
  { name: 'Read', weight: 0.3 },
  { name: 'Bash', weight: 0.25 },
  { name: 'Edit', weight: 0.15 },
  { name: 'Write', weight: 0.1 },
  { name: 'Grep', weight: 0.08 },
  { name: 'Glob', weight: 0.05 },
  { name: 'WebSearch', weight: 0.04 },
  { name: 'Skill', weight: 0.03 },
] as const;

const MOCK_SUMMARIES = [
  'Implemented authentication middleware with JWT token validation',
  'Refactored database connection pooling for better performance',
  'Fixed race condition in WebSocket event handler',
  'Added pagination to the session list API endpoint',
  'Migrated from CommonJS to ES modules across the project',
  'Debugged memory leak in the file watcher component',
  'Created unit tests for the pricing computation module',
  'Optimized SQLite queries with proper indexing strategy',
  'Built CLI tool for batch processing session exports',
  'Resolved CORS issues in the development proxy setup',
  'Implemented SSE endpoint for real-time session updates',
  'Added graceful shutdown with cleanup of open connections',
  'Configured CI pipeline with automated test coverage reporting',
  'Designed and implemented the background alert monitoring system',
  'Integrated semantic search with vector embeddings for sessions',
];

function weightedRandom<T extends { weight: number }>(items: readonly T[]): T {
  const total = items.reduce((sum, item) => sum + item.weight, 0);
  let r = Math.random() * total;
  for (const item of items) {
    r -= item.weight;
    if (r <= 0) return item;
  }
  return items[items.length - 1];
}

function randomInt(min: number, max: number): number {
  return Math.floor(Math.random() * (max - min + 1)) + min;
}

function randomDate(daysBack: number): Date {
  const now = Date.now();
  const offset = Math.random() * daysBack * 24 * 60 * 60 * 1000;
  return new Date(now - offset);
}

export async function populateMockData(db: Database): Promise<MockStats> {
  // Clear existing mock data first to ensure idempotency
  clearMockData(db);

  const rawDb = db.getRawDb();
  const SESSION_COUNT = 50;
  let totalCost = 0;
  let totalToolEntries = 0;

  const insertSession = rawDb.prepare(`
    INSERT INTO sessions (id, source, start_time, end_time, cwd, project, model,
      message_count, user_message_count, assistant_message_count, tool_message_count, system_message_count,
      summary, file_path, size_bytes, indexed_at, origin, tier)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, datetime('now'), 'local', ?)
  `);

  const insertCost = rawDb.prepare(`
    INSERT INTO session_costs (session_id, model, input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens, cost_usd, computed_at)
    VALUES (?, ?, ?, ?, ?, ?, ?, datetime('now'))
  `);

  const insertTool = rawDb.prepare(`
    INSERT INTO session_tools (session_id, tool_name, call_count)
    VALUES (?, ?, ?)
  `);

  const insertAll = rawDb.transaction(() => {
    for (let i = 0; i < SESSION_COUNT; i++) {
      const id = `mock-${randomUUID()}`;
      const source = weightedRandom(MOCK_SOURCES).name;
      const project = MOCK_PROJECTS[randomInt(0, MOCK_PROJECTS.length - 1)];
      const model = weightedRandom(MOCK_MODELS).name;
      const tier = weightedRandom(MOCK_TIERS).name;

      const startDate = randomDate(30);
      const durationMinutes = randomInt(5, 240);
      const endDate = new Date(
        startDate.getTime() + durationMinutes * 60 * 1000,
      );

      const messageCount = randomInt(5, 200);
      const userMsgCount = Math.floor(messageCount * 0.3);
      const assistantMsgCount = Math.floor(messageCount * 0.45);
      const toolMsgCount = Math.floor(messageCount * 0.2);
      const systemMsgCount =
        messageCount - userMsgCount - assistantMsgCount - toolMsgCount;

      const summary = MOCK_SUMMARIES[randomInt(0, MOCK_SUMMARIES.length - 1)];
      const cwd = `/Users/dev/projects/${project}`;
      const filePath = `__mock__/${id}.jsonl`;
      const sizeBytes = randomInt(5000, 500000);

      insertSession.run(
        id,
        source,
        startDate.toISOString(),
        endDate.toISOString(),
        cwd,
        project,
        model,
        messageCount,
        userMsgCount,
        assistantMsgCount,
        toolMsgCount,
        systemMsgCount,
        summary,
        filePath,
        sizeBytes,
        tier,
      );

      // Generate cost data
      const inputTokens = messageCount * randomInt(500, 3000);
      const outputTokens = messageCount * randomInt(50, 500);
      const cacheReadTokens = Math.floor(inputTokens * Math.random() * 0.8);
      const cacheCreationTokens = Math.floor(inputTokens * Math.random() * 0.3);
      const cost = computeCost(
        model,
        inputTokens,
        outputTokens,
        cacheReadTokens,
        cacheCreationTokens,
      );
      totalCost += cost;

      insertCost.run(
        id,
        model,
        inputTokens,
        outputTokens,
        cacheReadTokens,
        cacheCreationTokens,
        cost,
      );

      // Generate tool data (3-8 different tools per session)
      const toolCount = randomInt(3, 8);
      const usedTools = new Set<string>();
      for (let j = 0; j < toolCount; j++) {
        const tool = weightedRandom(MOCK_TOOLS);
        if (usedTools.has(tool.name)) continue;
        usedTools.add(tool.name);
        const callCount = randomInt(1, Math.floor(messageCount * 0.3) + 1);
        insertTool.run(id, tool.name, callCount);
        totalToolEntries++;
      }
    }
  });

  insertAll();

  return {
    sessions: SESSION_COUNT,
    tools: totalToolEntries,
    costUsd: Math.round(totalCost * 100) / 100,
  };
}

export function clearMockData(db: Database): number {
  const rawDb = db.getRawDb();
  // Foreign key cascading handles session_costs and session_tools
  const result = rawDb
    .prepare("DELETE FROM sessions WHERE file_path LIKE '__mock__%'")
    .run();
  return result.changes;
}
