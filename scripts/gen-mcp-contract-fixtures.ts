#!/usr/bin/env tsx
import { randomUUID } from 'node:crypto';
import { mkdirSync, rmSync, writeFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { Database } from '../src/core/db.js';
import { handleGetContext } from '../src/tools/get_context.js';
import { handleGetCosts } from '../src/tools/get_costs.js';
import { handleListSessions } from '../src/tools/list_sessions.js';
import { handleSaveInsight } from '../src/tools/save_insight.js';
import { handleSearch } from '../src/tools/search.js';
import { handleStats } from '../src/tools/stats.js';
import { handleToolAnalytics } from '../src/tools/tool_analytics.js';

const __dirname = dirname(fileURLToPath(import.meta.url));
const repoRoot = resolve(__dirname, '..');
const fixtureDbPath = resolve(repoRoot, 'tests/fixtures/mcp-contract.sqlite');
const goldenDir = resolve(repoRoot, 'tests/fixtures/mcp-golden');

rmSync(fixtureDbPath, { force: true });
rmSync(`${fixtureDbPath}-wal`, { force: true });
rmSync(`${fixtureDbPath}-shm`, { force: true });
rmSync(goldenDir, { recursive: true, force: true });
mkdirSync(goldenDir, { recursive: true });

const db = new Database(fixtureDbPath);
const raw = db.getRawDb();
raw.pragma('journal_mode = DELETE');

const insertSession = raw.prepare(`
  INSERT INTO sessions (
    id, source, start_time, end_time, cwd, project, model,
    message_count, user_message_count, assistant_message_count,
    tool_message_count, system_message_count, summary, file_path,
    size_bytes, indexed_at, agent_role, origin, tier, generated_title,
    quality_score
  ) VALUES (
    @id, @source, @startTime, @endTime, @cwd, @project, @model,
    @messageCount, @userMessageCount, @assistantMessageCount,
    @toolMessageCount, @systemMessageCount, @summary, @filePath,
    @sizeBytes, @indexedAt, @agentRole, @origin, @tier, @generatedTitle,
    @qualityScore
  )
`);

const insertCost = raw.prepare(`
  INSERT INTO session_costs (
    session_id, model, input_tokens, output_tokens,
    cache_read_tokens, cache_creation_tokens, cost_usd, computed_at
  ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
`);

const insertMetric = raw.prepare(`
  INSERT INTO metrics (name, type, value, tags, ts)
  VALUES (?, ?, ?, ?, ?)
`);

const insertInsight = raw.prepare(`
  INSERT INTO insights (
    id, content, wing, room, source_session_id,
    importance, has_embedding, created_at
  ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
`);
const insertInsightFts = raw.prepare(`
  INSERT INTO insights_fts (insight_id, content) VALUES (?, ?)
`);

const longBlock = (label: string) =>
  [
    `${label} discusses sqlite WAL, daemon HTTP forwarding, strict single writer, and Swift MCP contract parity.`,
    `The session touches search, get_context, stats, session_costs, and project aliases with deterministic fixture data.`,
    `This paragraph exists to make the checked-in SQLite fixture large enough for realistic contract testing.`,
  ]
    .join(' ')
    .repeat(6);

const sources = [
  ['claude-code', 'claude-sonnet-4-20250514'],
  ['codex', 'gpt-5.4'],
  ['gemini-cli', 'gemini-2.5-pro'],
  ['cursor', 'gpt-4o'],
  ['iflow', 'qwen-plus'],
  ['windsurf', 'sonnet'],
] as const;
const projects = [
  { name: 'engram', cwd: '/Users/test/work/engram' },
  { name: 'apollo', cwd: '/Users/test/work/apollo' },
  { name: 'delta-kit', cwd: '/Users/test/work/delta-kit' },
  { name: 'nova', cwd: '/Users/test/work/nova' },
] as const;

let sessionIndex = 1;
for (const project of projects) {
  for (const [source, model] of sources) {
    const id = `mcp-fixture-${String(sessionIndex).padStart(2, '0')}`;
    const day = String(((sessionIndex - 1) % 9) + 1).padStart(2, '0');
    const startTime = `2026-01-${day}T1${sessionIndex % 10}:00:00.000Z`;
    const endTime = `2026-01-${day}T1${sessionIndex % 10}:35:00.000Z`;
    const summary = `${project.name} ${source} session ${sessionIndex}: Swift MCP shim parity, WAL checkpoint behavior, and daemon forwarding`;
    insertSession.run({
      id,
      source,
      startTime,
      endTime,
      cwd: project.cwd,
      project: project.name,
      model,
      messageCount: 18 + (sessionIndex % 5),
      userMessageCount: 7 + (sessionIndex % 4),
      assistantMessageCount: 8 + (sessionIndex % 3),
      toolMessageCount: 2 + (sessionIndex % 2),
      systemMessageCount: 1,
      summary,
      filePath: `${project.cwd}/.fixtures/${id}.jsonl`,
      sizeBytes: 28000 + sessionIndex * 137,
      indexedAt: `2026-01-${day}T1${sessionIndex % 10}:40:00.000Z`,
      agentRole: null,
      origin: 'local',
      tier: sessionIndex % 7 === 0 ? 'lite' : 'normal',
      generatedTitle:
        sessionIndex % 4 === 0 ? `Generated ${project.name} ${source}` : null,
      qualityScore: 40 + sessionIndex,
    });

    db.indexSessionContent(
      id,
      [
        {
          role: 'user',
          content: `${project.name} asks about Swift MCP shim, stdio transport, project_move dry_run, and save_insight dedup.`,
        },
        {
          role: 'assistant',
          content: longBlock(
            `${project.name} ${source} assistant response ${sessionIndex}`,
          ),
        },
      ],
      summary,
    );

    db.upsertSessionTools(
      id,
      new Map([
        ['Read', 2 + (sessionIndex % 3)],
        ['Edit', 1 + (sessionIndex % 2)],
        ['Bash', 1],
        ['search', sessionIndex % 2],
      ]),
    );
    db.upsertSessionFiles(
      id,
      new Map([
        [
          `${project.cwd}/src/index.ts`,
          { action: 'Edit', count: 1 + (sessionIndex % 3) },
        ],
        [`${project.cwd}/src/tools/search.ts`, { action: 'Read', count: 2 }],
      ]),
    );
    insertCost.run(
      id,
      model,
      1200 + sessionIndex * 10,
      500 + sessionIndex * 5,
      50,
      10,
      Number((0.05 + sessionIndex * 0.003).toFixed(3)),
      `2026-01-${day}T1${sessionIndex % 10}:45:00.000Z`,
    );
    sessionIndex += 1;
  }
}

for (let i = 1; i <= 10; i += 1) {
  const id = `insight-${String(i).padStart(2, '0')}`;
  const content = `Insight ${i}: Engram should keep write traffic on daemon HTTP only, with deterministic Swift MCP contract tests and WAL-friendly single-writer semantics.`;
  const wing = i <= 6 ? 'engram' : 'apollo';
  insertInsight.run(
    id,
    content,
    wing,
    i % 2 === 0 ? 'mcp-swift' : 'contracts',
    `mcp-fixture-${String(i).padStart(2, '0')}`,
    5 - (i % 3),
    0,
    `2026-02-${String(i).padStart(2, '0')}T08:00:00.000Z`,
  );
  insertInsightFts.run(id, content);
}

db.addProjectAlias('engram-mcp', 'engram');
db.addProjectAlias('engram-legacy', 'engram');
db.addProjectAlias('apollo-old', 'apollo');

insertMetric.run(
  'search.fts_ms',
  'histogram',
  42,
  '{"tool":"search"}',
  '2026-02-01T10:00:00.000Z',
);
insertMetric.run(
  'tool.invocations',
  'counter',
  12,
  '{"tool":"stats"}',
  '2026-02-01T10:01:00.000Z',
);
insertMetric.run('db.wal_frames', 'gauge', 8, '{}', '2026-02-01T10:02:00.000Z');
insertMetric.run(
  'http.requests',
  'counter',
  6,
  '{"path":"/api/insight"}',
  '2026-02-01T10:03:00.000Z',
);
insertMetric.run(
  'search.vector_ms',
  'histogram',
  0,
  '{"tool":"search"}',
  '2026-02-01T10:04:00.000Z',
);

type MCPResponse = {
  content: Array<{ type: string; text: string }>;
  structuredContent?: unknown;
  isError?: boolean;
};

function success(result: unknown): MCPResponse {
  return {
    content: [{ type: 'text', text: JSON.stringify(result, null, 2) }],
    structuredContent: result,
  };
}

function early(text: string, isError = false): MCPResponse {
  return {
    content: [{ type: 'text', text }],
    ...(isError ? { isError: true } : {}),
  };
}

function normalizeDynamic(value: unknown): unknown {
  const json = JSON.parse(
    JSON.stringify(value, (_key, current) => {
      if (typeof current === 'string') {
        if (
          /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(
            current,
          )
        ) {
          return '<generated-uuid>';
        }
      }
      return current;
    }),
  );
  return json;
}

const goldens: Record<string, unknown> = {
  'stats.source': success(
    await handleStats(db, {
      group_by: 'source',
      since: '2026-01-01T00:00:00.000Z',
    }),
  ),
  'search.keyword': success(
    await handleSearch(db, {
      query: 'Swift MCP shim',
      mode: 'keyword',
      limit: 5,
    }),
  ),
  'get_context.engram': early(
    (
      await handleGetContext(
        db,
        {
          cwd: '/Users/test/work/engram',
          task: 'port engram mcp shim to swift',
          include_environment: false,
          sort_by: 'score',
        },
        {},
      )
    ).contextText,
  ),
  'list_sessions.engram': success(
    await handleListSessions(db, {
      project: 'engram',
      since: '2026-01-01T00:00:00.000Z',
      limit: 4,
      offset: 0,
    }),
  ),
  'get_costs.project': success(
    handleGetCosts(db, {
      group_by: 'project',
      since: '2026-01-01T00:00:00.000Z',
    }),
  ),
  'tool_analytics.tool': success(
    handleToolAnalytics(db, {
      group_by: 'tool',
      since: '2026-01-01T00:00:00.000Z',
    }),
  ),
  'manage_project_alias.list': success(db.listProjectAliases()),
  'manage_project_alias.add': success(
    (() => {
      db.addProjectAlias('apollo-next', 'apollo');
      return { added: { alias: 'apollo-next', canonical: 'apollo' } };
    })(),
  ),
  'manage_project_alias.remove': success(
    (() => {
      db.removeProjectAlias('apollo-next', 'apollo');
      return { removed: { alias: 'apollo-next', canonical: 'apollo' } };
    })(),
  ),
  'save_insight.text_only': success(
    normalizeDynamic(
      await handleSaveInsight(
        {
          content:
            'Swift MCP contract tests should use deterministic fixture databases and byte-stable JSON golden files.',
          wing: 'engram',
          room: 'mcp-swift',
          importance: 5,
          source_session_id: 'mcp-fixture-01',
        },
        { db },
      ),
    ),
  ),
};

for (const [name, payload] of Object.entries(goldens)) {
  writeFileSync(
    resolve(goldenDir, `${name}.json`),
    `${JSON.stringify(payload, null, 2)}\n`,
  );
}

writeFileSync(
  resolve(goldenDir, 'README.md'),
  [
    '# MCP Golden Fixtures',
    '',
    'Generated by `npm run generate:mcp-contract-fixtures`.',
    '',
    'Normalization rules:',
    '- random UUIDs in write-tool responses are replaced with `<generated-uuid>`',
    '- all timestamps come from fixed fixture rows, not `now()`',
    '- fixture DB is `tests/fixtures/mcp-contract.sqlite`; never use `~/.engram/index.sqlite` in contract tests',
    '',
  ].join('\n'),
);

db.close();

console.log(`Generated ${fixtureDbPath}`);
console.log(`Generated goldens in ${goldenDir}`);
