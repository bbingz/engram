#!/usr/bin/env tsx
// IMPORTANT: always run with TZ=UTC so golden timestamps match the xctest
// environment, which itself runs under UTC regardless of the host TZ.
// Example:  TZ=UTC ./node_modules/.bin/tsx scripts/gen-mcp-contract-fixtures.ts
// Without TZ=UTC the generator emits host-local times (e.g. +08:00 CST) while
// xctest outputs UTC — 5 goldens with timestamps would silently diverge.
import {
  mkdirSync,
  mkdtempSync,
  readdirSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { CodexAdapter } from '../src/adapters/codex.js';
import { Database } from '../src/core/db.js';
import { handleExport } from '../src/tools/export.js';
import { handleFileActivity } from '../src/tools/file_activity.js';
import { handleGetContext } from '../src/tools/get_context.js';
import { handleGetCosts } from '../src/tools/get_costs.js';
import { handleGetInsights } from '../src/tools/get_insights.js';
import { handleGetMemory } from '../src/tools/get_memory.js';
import { handleGetSession } from '../src/tools/get_session.js';
import { handleHandoff } from '../src/tools/handoff.js';
import { handleInspectSession } from '../src/tools/inspect_session.js';
import { handleLinkSessions } from '../src/tools/link_sessions.js';
import { handleLintConfig } from '../src/tools/lint_config.js';
import { handleListSessions } from '../src/tools/list_sessions.js';
import { handleLiveSessions } from '../src/tools/live_sessions.js';
import {
  handleProjectListMigrations,
  handleProjectRecover,
  handleProjectReview,
} from '../src/tools/project.js';
import { handleProjectTimeline } from '../src/tools/project_timeline.js';
import { handleSaveInsight } from '../src/tools/save_insight.js';
import { handleSearch } from '../src/tools/search.js';
import { handleStats } from '../src/tools/stats.js';
import { handleToolAnalytics } from '../src/tools/tool_analytics.js';

const __dirname = dirname(fileURLToPath(import.meta.url));
const repoRoot = resolve(__dirname, '..');
const fixtureDbPath = resolve(repoRoot, 'tests/fixtures/mcp-contract.sqlite');
const goldenDir = resolve(repoRoot, 'tests/fixtures/mcp-golden');
const runtimeDir = resolve(repoRoot, 'tests/fixtures/mcp-runtime');
const lintProjectDir = resolve(runtimeDir, 'lint-project');
const linkTargetDir = resolve(runtimeDir, 'engram');
const reviewHomeDir = resolve(runtimeDir, 'review-home');
const transcriptDir = resolve(runtimeDir, 'transcripts');
const exportHomeDir = resolve(runtimeDir, 'export-home');
// tools.json is a Swift MCP parity fixture, not a Node allTools dump.
// List tools the Node MCP server exposes that the Swift MCP registry does
// not (yet) expose, so they get filtered out before writing tools.json.
// Keep this list narrow: when a Swift counterpart lands, drop the entry.
const swiftUnavailableTools = new Set(['delete_insight', 'inspect_session']);

rmSync(fixtureDbPath, { force: true });
rmSync(`${fixtureDbPath}-wal`, { force: true });
rmSync(`${fixtureDbPath}-shm`, { force: true });
rmSync(goldenDir, { recursive: true, force: true });
rmSync(runtimeDir, { recursive: true, force: true });
mkdirSync(goldenDir, { recursive: true });
mkdirSync(runtimeDir, { recursive: true });
mkdirSync(transcriptDir, { recursive: true });

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
const insertMigration = raw.prepare(`
  INSERT INTO migration_log (
    id, old_path, new_path, old_basename, new_basename,
    state, files_patched, occurrences, sessions_updated, alias_created,
    cc_dir_renamed, started_at, finished_at, dry_run, rolled_back_of,
    audit_note, archived, actor, detail, error
  ) VALUES (
    @id, @oldPath, @newPath, @oldBasename, @newBasename,
    @state, @filesPatched, @occurrences, @sessionsUpdated, @aliasCreated,
    @ccDirRenamed, @startedAt, @finishedAt, @dryRun, @rolledBackOf,
    @auditNote, @archived, @actor, @detail, @error
  )
`);
const insertProjectAlias = raw.prepare(`
  INSERT OR IGNORE INTO project_aliases (alias, canonical, created_at)
  VALUES (?, ?, ?)
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

insertProjectAlias.run('engram-mcp', 'engram', '2026-02-01T09:00:00.000Z');
insertProjectAlias.run('engram-legacy', 'engram', '2026-02-01T09:00:00.000Z');
insertProjectAlias.run('apollo-old', 'apollo', '2026-02-01T09:00:00.000Z');

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

for (const row of [
  {
    id: 'mig-003',
    oldPath: '/Users/test/work/engram-old',
    newPath: '/Users/test/work/engram',
    oldBasename: 'engram-old',
    newBasename: 'engram',
    state: 'committed',
    filesPatched: 12,
    occurrences: 44,
    sessionsUpdated: 8,
    aliasCreated: 1,
    ccDirRenamed: 1,
    startedAt: '2026-03-03T10:00:00.000Z',
    finishedAt: '2026-03-03T10:01:00.000Z',
    dryRun: 0,
    rolledBackOf: null,
    auditNote: 'fixture committed move',
    archived: 0,
    actor: 'mcp',
    detail: JSON.stringify({ source: 'fixture', kind: 'move' }),
    error: null,
  },
  {
    id: 'mig-002',
    oldPath: '/Users/test/work/apollo',
    newPath: '/Users/test/work/_archive/archived-done/apollo',
    oldBasename: 'apollo',
    newBasename: 'apollo',
    state: 'failed',
    filesPatched: 3,
    occurrences: 9,
    sessionsUpdated: 0,
    aliasCreated: 0,
    ccDirRenamed: 0,
    startedAt: '2026-03-02T09:00:00.000Z',
    finishedAt: '2026-03-02T09:00:30.000Z',
    dryRun: 0,
    rolledBackOf: null,
    auditNote: 'fixture archive failure',
    archived: 1,
    actor: 'cli',
    detail: JSON.stringify({ source: 'fixture', kind: 'archive' }),
    error: 'git dirty',
  },
  {
    id: 'mig-001',
    oldPath: '/Users/test/work/delta-kit',
    newPath: '/Users/test/work/delta-kit-v2',
    oldBasename: 'delta-kit',
    newBasename: 'delta-kit-v2',
    state: 'fs_done',
    filesPatched: 7,
    occurrences: 22,
    sessionsUpdated: 0,
    aliasCreated: 0,
    ccDirRenamed: 0,
    startedAt: '2026-03-01T08:00:00.000Z',
    finishedAt: null,
    dryRun: 1,
    rolledBackOf: null,
    auditNote: 'fixture dry run',
    archived: 0,
    actor: 'batch',
    detail: JSON.stringify({ source: 'fixture', kind: 'dry-run' }),
    error: null,
  },
]) {
  insertMigration.run(row);
}

mkdirSync(resolve(lintProjectDir, 'src'), { recursive: true });
writeFileSync(
  resolve(lintProjectDir, 'CLAUDE.md'),
  [
    '# Fixture Lint Project',
    '',
    'Run `npm run build` before release.',
    'Document `src/present.ts` and `npm run verify` in the onboarding guide.',
  ].join('\n'),
);
writeFileSync(
  resolve(lintProjectDir, 'package.json'),
  JSON.stringify(
    {
      name: 'mcp-lint-fixture',
      private: true,
      scripts: {
        build: 'echo build',
      },
    },
    null,
    2,
  ),
);
writeFileSync(
  resolve(lintProjectDir, 'src/existing.ts'),
  'export const fixture = true;\n',
);

mkdirSync(linkTargetDir, { recursive: true });

const reviewOwnDir = resolve(
  reviewHomeDir,
  '.claude/projects',
  '-Users-test-work-engram-v2',
);
const reviewOtherDir = resolve(
  reviewHomeDir,
  '.claude/projects',
  '-Users-test-work-other-app',
);
const reviewCodexDir = resolve(reviewHomeDir, '.codex/sessions/2026/04/22');
mkdirSync(reviewOwnDir, { recursive: true });
mkdirSync(reviewOtherDir, { recursive: true });
mkdirSync(reviewCodexDir, { recursive: true });
writeFileSync(
  resolve(reviewOwnDir, 'session-own.jsonl'),
  `${JSON.stringify({ old: '/Users/test/work/engram-old', note: 'own scope' })}\n`,
);
writeFileSync(
  resolve(reviewOtherDir, 'session-other.jsonl'),
  `${JSON.stringify({ old: '/Users/test/work/engram-old', note: 'other scope' })}\n`,
);
writeFileSync(
  resolve(reviewCodexDir, 'rollout-review.jsonl'),
  `${JSON.stringify({
    note: 'codex still references /Users/test/work/engram-old',
  })}\n`,
);

const transcriptRelativePath =
  'tests/fixtures/mcp-runtime/transcripts/rollout-mcp-transcript-01.jsonl';
const transcriptPath = resolve(repoRoot, transcriptRelativePath);
writeFileSync(
  transcriptPath,
  [
    JSON.stringify({
      type: 'session_meta',
      payload: {
        id: 'mcp-transcript-01',
        timestamp: '2026-01-15T09:00:00.000Z',
        cwd: '/Users/test/work/transcript-fixture',
        model_provider: 'gpt-5.4',
      },
    }),
    JSON.stringify({
      type: 'response_item',
      timestamp: '2026-01-15T09:00:00.000Z',
      payload: {
        type: 'message',
        role: 'user',
        content: [
          { text: 'Summarize the Swift MCP shim scope before implementation.' },
        ],
      },
    }),
    JSON.stringify({
      type: 'response_item',
      timestamp: '2026-01-15T09:01:00.000Z',
      payload: {
        type: 'message',
        role: 'assistant',
        content: [
          {
            text: 'Phase C only ports the MCP stdio shim and daemon forwarding layer.',
          },
        ],
      },
    }),
    JSON.stringify({
      type: 'response_item',
      timestamp: '2026-01-15T09:02:00.000Z',
      payload: {
        type: 'message',
        role: 'user',
        content: [{ text: 'Keep src/index.ts as the fallback entry point.' }],
      },
    }),
    '',
  ].join('\n'),
);

insertSession.run({
  id: 'mcp-transcript-01',
  source: 'codex',
  startTime: '2026-01-15T09:00:00.000Z',
  endTime: '2026-01-15T09:05:00.000Z',
  cwd: '/Users/test/work/transcript-fixture',
  project: 'transcript-fixture',
  model: 'gpt-5.4',
  messageCount: 3,
  userMessageCount: 2,
  assistantMessageCount: 1,
  toolMessageCount: 0,
  systemMessageCount: 0,
  summary:
    'Transcript fixture codex session for get_session/export contract tests',
  filePath: transcriptRelativePath,
  sizeBytes: 2048,
  indexedAt: '2026-01-15T09:06:00.000Z',
  agentRole: null,
  origin: 'local',
  tier: 'normal',
  generatedTitle: null,
  qualityScore: 55,
});

const codexAdapter = new CodexAdapter();

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

function earlyWithMetadata(
  text: string,
  metadata: Record<string, unknown>,
  isError = false,
): MCPResponse {
  return {
    content: [{ type: 'text', text }],
    metadata,
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

async function withMockedNow<T>(isoTimestamp: string, run: () => Promise<T>) {
  const RealDate = Date;
  const fixedTime = new RealDate(isoTimestamp).getTime();
  class MockDate extends RealDate {
    constructor(value?: string | number | Date) {
      super(value === undefined ? fixedTime : value);
    }

    static now() {
      return fixedTime;
    }

    static parse(text: string) {
      return RealDate.parse(text);
    }

    static UTC(...args: Parameters<typeof RealDate.UTC>) {
      return RealDate.UTC(...args);
    }
  }

  globalThis.Date = MockDate as unknown as DateConstructor;
  try {
    return await run();
  } finally {
    globalThis.Date = RealDate;
  }
}

// Build the inspector golden in an isolated, throwaway Database so the seed
// rows (mcp-inspector-parent / child / suggested + cost + audit) never leak
// into the shared mcp-contract.sqlite that other goldens read from.
async function buildInspectorGolden(): Promise<MCPResponse> {
  const tmpRoot = mkdtempSync(resolve(tmpdir(), 'mcp-inspector-golden-'));
  const tmpDbPath = resolve(tmpRoot, 'inspector.sqlite');
  const tmpDb = new Database(tmpDbPath);
  try {
    const tmpRaw = tmpDb.getRawDb();
    tmpRaw.pragma('journal_mode = DELETE');

    const insertInspectorSession = tmpRaw.prepare(`
      INSERT INTO sessions (
        id, source, start_time, end_time, cwd, project, model,
        message_count, user_message_count, assistant_message_count,
        tool_message_count, system_message_count, summary,
        summary_message_count, file_path, size_bytes, indexed_at,
        agent_role, origin, tier, generated_title, quality_score,
        parent_session_id, suggested_parent_id, link_source
      ) VALUES (
        @id, @source, @startTime, @endTime, @cwd, @project, @model,
        @messageCount, @userMessageCount, @assistantMessageCount,
        @toolMessageCount, @systemMessageCount, @summary,
        @summaryMessageCount, @filePath, @sizeBytes, @indexedAt,
        @agentRole, @origin, @tier, @generatedTitle, @qualityScore,
        @parentSessionId, @suggestedParentId, @linkSource
      )
    `);

    insertInspectorSession.run({
      id: 'mcp-inspector-parent',
      source: 'codex',
      startTime: '2026-05-07T08:00:00.000Z',
      endTime: '2026-05-07T08:30:00.000Z',
      cwd: '/Users/test/work/engram',
      project: 'engram',
      model: 'gpt-5.4',
      messageCount: 8,
      userMessageCount: 3,
      assistantMessageCount: 4,
      toolMessageCount: 1,
      systemMessageCount: 0,
      summary: 'Inspector fixture parent session',
      summaryMessageCount: 8,
      filePath: '/Users/test/work/engram/.fixtures/mcp-inspector-parent.jsonl',
      sizeBytes: 2048,
      indexedAt: '2026-05-07T08:31:00.000Z',
      agentRole: null,
      origin: 'local',
      tier: 'normal',
      generatedTitle: 'Inspector golden parent',
      qualityScore: 60,
      parentSessionId: null,
      suggestedParentId: null,
      linkSource: null,
    });

    insertInspectorSession.run({
      id: 'mcp-inspector-child-codex',
      source: 'codex',
      startTime: '2026-05-07T08:05:00.000Z',
      endTime: '2026-05-07T08:10:00.000Z',
      cwd: '/Users/test/work/engram',
      project: 'engram',
      model: 'gpt-5.4',
      messageCount: 4,
      userMessageCount: 2,
      assistantMessageCount: 2,
      toolMessageCount: 0,
      systemMessageCount: 0,
      summary: 'Inspector fixture confirmed child',
      summaryMessageCount: null,
      filePath:
        '/Users/test/work/engram/.fixtures/mcp-inspector-child-codex.jsonl',
      sizeBytes: 600,
      indexedAt: '2026-05-07T08:31:00.000Z',
      agentRole: 'dispatched',
      origin: 'local',
      tier: 'skip',
      generatedTitle: null,
      qualityScore: 30,
      parentSessionId: 'mcp-inspector-parent',
      suggestedParentId: null,
      linkSource: 'path',
    });

    insertInspectorSession.run({
      id: 'mcp-inspector-suggested-gemini',
      source: 'gemini-cli',
      startTime: '2026-05-07T08:25:00.000Z',
      endTime: null,
      cwd: '/Users/test/work/engram',
      project: 'engram',
      model: 'gemini-2.5-pro',
      messageCount: 3,
      userMessageCount: 1,
      assistantMessageCount: 2,
      toolMessageCount: 0,
      systemMessageCount: 0,
      summary: 'Inspector fixture suggested child',
      summaryMessageCount: null,
      filePath:
        '/Users/test/work/engram/.fixtures/mcp-inspector-suggested-gemini.jsonl',
      sizeBytes: 500,
      indexedAt: '2026-05-07T08:31:00.000Z',
      agentRole: 'dispatched',
      origin: 'local',
      tier: 'skip',
      generatedTitle: null,
      qualityScore: 25,
      parentSessionId: null,
      suggestedParentId: 'mcp-inspector-parent',
      linkSource: null,
    });

    const insertInspectorCost = tmpRaw.prepare(`
      INSERT INTO session_costs (
        session_id, model, input_tokens, output_tokens,
        cache_read_tokens, cache_creation_tokens, cost_usd, computed_at
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
    `);
    insertInspectorCost.run(
      'mcp-inspector-parent',
      'gpt-5.4',
      1000,
      500,
      0,
      0,
      0.5,
      '2026-05-07T08:31:00.000Z',
    );
    insertInspectorCost.run(
      'mcp-inspector-child-codex',
      'gpt-5.4',
      100,
      100,
      0,
      0,
      0.125,
      '2026-05-07T08:31:00.000Z',
    );

    // Redacted summary audit row — request/response bodies left null so the
    // golden never carries Authorization headers, Gemini URL keys, or any
    // provider secret. Fixed ts so the golden is byte-stable.
    tmpRaw
      .prepare(`
        INSERT INTO ai_audit_log (
          ts, trace_id, caller, operation, request_source, method, url,
          status_code, duration_ms, model, provider,
          prompt_tokens, completion_tokens, total_tokens,
          request_body, response_body, error, session_id, meta
        ) VALUES (
          @ts, NULL, @caller, @operation, NULL, NULL, NULL, NULL,
          @durationMs, @model, @provider,
          @promptTokens, @completionTokens, @totalTokens,
          NULL, NULL, NULL, @sessionId, @meta
        )
      `)
      .run({
        ts: '2026-05-07T08:31:00.000',
        caller: 'summary',
        operation: 'summarize',
        durationMs: 14,
        model: 'gpt-5.4',
        provider: 'openai',
        promptTokens: 200,
        completionTokens: 50,
        totalTokens: 250,
        sessionId: 'mcp-inspector-parent',
        meta: JSON.stringify({
          trigger: 'manual',
          messageCount: 8,
          sampledMessageCount: 8,
          resolvedConfig: {
            preset: 'standard',
            maxTokens: 200,
            temperature: 0.3,
            sampleFirst: 20,
            sampleLast: 30,
            truncateChars: 500,
          },
        }),
      });

    const result = await handleInspectSession(tmpDb, {
      id: 'mcp-inspector-parent',
    });
    return result as MCPResponse;
  } finally {
    tmpDb.close();
    rmSync(tmpRoot, { recursive: true, force: true });
  }
}

// save_insight returns a normalized UUID in the golden output, but the real
// handler also writes that random UUID into its database. Keep that mutation
// out of the shared contract DB so mcp-contract.sqlite can be byte-stable.
async function buildSaveInsightGolden(): Promise<MCPResponse> {
  const tmpRoot = mkdtempSync(resolve(tmpdir(), 'mcp-save-insight-golden-'));
  const tmpDbPath = resolve(tmpRoot, 'save-insight.sqlite');
  const tmpDb = new Database(tmpDbPath);
  try {
    const result = await handleSaveInsight(
      {
        content:
          'Swift MCP contract tests should use deterministic fixture databases and byte-stable JSON golden files.',
        wing: 'engram',
        room: 'mcp-swift',
        importance: 5,
        source_session_id: 'mcp-fixture-01',
      },
      { db: tmpDb },
    );
    return success(normalizeDynamic(result));
  } finally {
    tmpDb.close();
    rmSync(tmpRoot, { recursive: true, force: true });
  }
}

const goldens: Record<string, unknown> = {
  'initialize.result': extractInitializeResultFromIndex(),
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
  'search.hybrid.keyword_only': success(
    await handleSearch(db, {
      query: 'single writer daemon HTTP',
      mode: 'hybrid',
      limit: 5,
    }),
  ),
  'search.semantic.short_query': success(
    await handleSearch(db, {
      query: 'ab',
      mode: 'semantic',
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
  'get_context.engram.with_memory': early(
    (
      await handleGetContext(
        db,
        {
          cwd: '/Users/test/work/engram',
          task: 'daemon HTTP single writer',
          include_environment: false,
          sort_by: 'score',
        },
        {},
      )
    ).contextText,
  ),
  'get_context.engram.abstract_environment': early(
    (
      await withMockedNow('2026-01-09T12:00:00.000Z', async () =>
        handleGetContext(
          db,
          {
            cwd: '/Users/test/work/engram',
            detail: 'abstract',
            include_environment: true,
            sort_by: 'score',
          },
          {},
        ),
      )
    ).contextText,
  ),
  'get_insights.empty': success(
    await handleGetInsights(
      db,
      {},
      {
        since: '2026-02-15T00:00:00.000Z',
      },
    ),
  ),
  'get_session.transcript': success(
    await handleGetSession(db, codexAdapter, {
      id: 'mcp-transcript-01',
      page: 1,
    }),
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
  'file_activity.engram': success(
    handleFileActivity(db, {
      project: 'engram',
      since: '2026-01-01T00:00:00.000Z',
      limit: 4,
    }),
  ),
  'project_timeline.engram': success(
    await handleProjectTimeline(db, {
      project: 'engram',
      since: '2026-01-01T00:00:00.000Z',
    }),
  ),
  'project_list_migrations.recent': success(
    handleProjectListMigrations(db, {
      since: '2026-03-01T00:00:00.000Z',
      limit: 3,
    }),
  ),
  'live_sessions.unavailable': success(handleLiveSessions(null)),
  'get_memory.keyword': success(
    await handleGetMemory({ query: 'single writer daemon HTTP' }, { db }),
  ),
  'lint_config.fixture': success(
    await handleLintConfig({
      cwd: lintProjectDir,
    }),
  ),
  'export.transcript': success(
    await (async () => {
      const previousHome = process.env.HOME;
      process.env.HOME = exportHomeDir;
      try {
        return await handleExport(db, codexAdapter, {
          id: 'mcp-transcript-01',
          format: 'json',
        });
      } finally {
        process.env.HOME = previousHome;
      }
    })(),
  ),
  'handoff.empty': success(
    await handleHandoff(
      db,
      {
        cwd: '/Users/test/work/missing-project',
        format: 'markdown',
      },
      undefined,
    ),
  ),
  'link_sessions.engram': success(
    await handleLinkSessions(db, {
      targetDir: linkTargetDir,
    }),
  ),
  'manage_project_alias.list': success(db.listProjectAliases()),
  'manage_project_alias.add': success(
    (() => {
      insertProjectAlias.run(
        'apollo-next',
        'apollo',
        '2026-02-01T09:00:00.000Z',
      );
      return { added: { alias: 'apollo-next', canonical: 'apollo' } };
    })(),
  ),
  'manage_project_alias.remove': success(
    (() => {
      db.removeProjectAlias('apollo-next', 'apollo');
      return { removed: { alias: 'apollo-next', canonical: 'apollo' } };
    })(),
  ),
  'save_insight.text_only': await buildSaveInsightGolden(),
  'project_review.fixture': success(
    await (async () => {
      const previousHome = process.env.HOME;
      process.env.HOME = reviewHomeDir;
      try {
        return await handleProjectReview({
          old_path: '/Users/test/work/engram-old',
          new_path: '/Users/test/work/engram-v2',
          max_items: 100,
        });
      } finally {
        process.env.HOME = previousHome;
      }
    })(),
  ),
  'project_recover.fixture': success(
    await handleProjectRecover(db, {
      since: '2026-03-01T00:00:00.000Z',
    }),
  ),
  'session_inspector.fixture': await buildInspectorGolden(),
};

Object.assign(goldens, {
  'generate_summary.fixture': earlyWithMetadata(
    'Fixture summary: Phase C ports the stdio MCP shim and forwards writes through daemon HTTP.',
    { sessionId: 'mcp-fixture-01' },
  ),
});

// Normalize the host repoRoot so goldens stay byte-stable across machines.
// Convention: repoRoot → /Users/example/-Code-/engram
const NORMALIZED_REPO_ROOT = '/Users/example/-Code-/engram';
function normalizeRepoRoot(text: string): string {
  return text.split(repoRoot).join(NORMALIZED_REPO_ROOT);
}

for (const [name, payload] of Object.entries(goldens)) {
  const json = JSON.stringify(payload, null, 2);
  writeFileSync(
    resolve(goldenDir, `${name}.json`),
    `${normalizeRepoRoot(json)}\n`,
  );
}

// Post-process tracked runtime artifacts (e.g., codex export written by
// handleExport above) so they don't carry the local /Users/bing path either.
// Also ensure a trailing newline to match the on-disk convention for these
// goldens (the committed version has one; preserving it keeps the diff
// minimal across regeneration runs).
const exportArtifactDir = resolve(exportHomeDir, 'codex-exports');
try {
  for (const entry of readdirSync(exportArtifactDir)) {
    const filePath = resolve(exportArtifactDir, entry);
    const original = readFileSync(filePath, 'utf8');
    const normalized = normalizeRepoRoot(original);
    const withTrailingNewline = normalized.endsWith('\n')
      ? normalized
      : `${normalized}\n`;
    if (withTrailingNewline !== original) {
      writeFileSync(filePath, withTrailingNewline);
    }
  }
} catch {
  // intentional: handleExport may not have produced any artifact this run
}

writeFileSync(
  resolve(goldenDir, 'tools.json'),
  `${JSON.stringify(extractToolNamesFromIndex(), null, 2)}\n`,
);

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
    '- inspector fixtures (`session_inspector.fixture.json`) are produced from local DB facts only — no LLM provider calls, no transcript streaming, no external CLI; `resume.command`/`resume.args` stay absent because no resolver is provided',
    '- provider secrets, Authorization headers, Gemini URL keys, and secret-like body values must be redacted before entering golden output (audit rows seeded for the inspector golden have request/response bodies set to NULL)',
    '',
  ].join('\n'),
);

db.close();

console.log(`Generated ${fixtureDbPath}`);
console.log(`Generated goldens in ${goldenDir}`);

function extractToolNamesFromIndex(): string[] {
  const indexPath = resolve(repoRoot, 'src/index.ts');
  const indexSource = readFileSync(indexPath, 'utf8');
  const importMap = new Map<string, string>();
  for (const match of indexSource.matchAll(
    /import\s*\{([\s\S]*?)\}\s*from\s*'([^']+)'/g,
  )) {
    const names = match[1]
      .split(',')
      .map((part) => part.trim())
      .filter(Boolean);
    for (const name of names) {
      const [imported, local] = name.split(/\s+as\s+/);
      importMap.set((local ?? imported).trim(), match[2]);
    }
  }

  const blockMatch = indexSource.match(/const allTools = \[([\s\S]*?)\n\];/);
  if (!blockMatch) {
    throw new Error('Unable to locate allTools block in src/index.ts');
  }

  const blockWithoutComments = blockMatch[1].replace(/^\s*\/\/.*$/gm, '');
  const entries = splitTopLevelEntries(blockWithoutComments);
  return entries
    .map((entry) => entry.trim())
    .filter((entry) => entry.length > 0)
    .map((entry) => resolveToolName(entry, importMap))
    .filter((toolName) => !swiftUnavailableTools.has(toolName));
}

function extractInitializeResultFromIndex(): Record<string, unknown> {
  const swiftServerPath = resolve(
    repoRoot,
    'macos/EngramMCP/Core/MCPStdioServer.swift',
  );
  const swiftServerSource = readFileSync(swiftServerPath, 'utf8');
  const instructionsMatch = swiftServerSource.match(
    /private static let instructions = """\n([\s\S]*?)\n {4}"""/,
  );

  if (!instructionsMatch) {
    throw new Error(
      'Unable to locate MCPStdioServer instructions multiline literal',
    );
  }
  const instructions = instructionsMatch[1]
    .split('\n')
    .map((line) => (line.startsWith('    ') ? line.slice(4) : line))
    .join('\n');

  return {
    protocolVersion: '2025-03-26',
    capabilities: { tools: {} },
    serverInfo: { name: 'engram', version: '0.1.0' },
    instructions,
  };
}

function splitTopLevelEntries(block: string): string[] {
  const entries: string[] = [];
  let current = '';
  let braceDepth = 0;
  let bracketDepth = 0;
  let parenDepth = 0;
  let inString = false;
  let stringQuote = '';
  let escaped = false;

  for (const char of block) {
    current += char;

    if (inString) {
      if (escaped) {
        escaped = false;
        continue;
      }
      if (char === '\\') {
        escaped = true;
        continue;
      }
      if (char === stringQuote) {
        inString = false;
        stringQuote = '';
      }
      continue;
    }

    if (char === "'" || char === '"' || char === '`') {
      inString = true;
      stringQuote = char;
      continue;
    }
    if (char === '{') braceDepth += 1;
    else if (char === '}') braceDepth -= 1;
    else if (char === '[') bracketDepth += 1;
    else if (char === ']') bracketDepth -= 1;
    else if (char === '(') parenDepth += 1;
    else if (char === ')') parenDepth -= 1;
    else if (
      char === ',' &&
      braceDepth === 0 &&
      bracketDepth === 0 &&
      parenDepth === 0
    ) {
      entries.push(current.slice(0, -1));
      current = '';
    }
  }

  if (current.trim()) {
    entries.push(current);
  }
  return entries.filter((entry) => entry.trim().length > 0);
}

function resolveToolName(
  entry: string,
  importMap: Map<string, string>,
): string {
  entry = entry.replace(/^\s*\/\/.*$/gm, '').trim();
  if (entry.startsWith('{')) {
    const match = entry.match(/name:\s*'([^']+)'/);
    if (!match) {
      throw new Error(`Unable to extract inline tool name from: ${entry}`);
    }
    return match[1];
  }

  const identifier = entry.replace(/,$/, '').trim();
  const relativeImport = importMap.get(identifier);
  if (!relativeImport) {
    const indexSource = readFileSync(resolve(repoRoot, 'src/index.ts'), 'utf8');
    const localMatch = indexSource.match(
      new RegExp(
        String.raw`const ${identifier}\s*=\s*\{[\s\S]*?name:\s*'([^']+)'`,
      ),
    );
    if (localMatch) {
      return localMatch[1];
    }
    throw new Error(`Missing import for allTools entry: ${identifier}`);
  }

  const sourcePath = resolve(
    repoRoot,
    'src',
    relativeImport.replace(/^\.\//, '').replace(/\.js$/, '.ts'),
  );
  const source = readFileSync(sourcePath, 'utf8');
  const match = source.match(
    new RegExp(
      String.raw`export const ${identifier}\s*=\s*\{[\s\S]*?name:\s*'([^']+)'`,
    ),
  );
  if (!match) {
    throw new Error(
      `Unable to resolve tool name for ${identifier} from ${sourcePath}`,
    );
  }
  return match[1];
}
