#!/usr/bin/env tsx
// IMPORTANT: always run with TZ=UTC so fixture timestamps and SQLite bytes are
// stable across local and CI environments.
// Example:  TZ=UTC npm run generate:mcp-contract-fixtures
// Behavioral response goldens are owned by the native Swift executable tests;
// this generator only owns the database, runtime inputs, and Swift metadata.
import {
  mkdirSync,
  readFileSync,
  rmSync,
  symlinkSync,
  writeFileSync,
} from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { Database } from '../src/core/db.js';

const __dirname = dirname(fileURLToPath(import.meta.url));
const repoRoot = resolve(__dirname, '..');
const fixtureDbPath = resolve(repoRoot, 'tests/fixtures/mcp-contract.sqlite');
const goldenDir = resolve(repoRoot, 'tests/fixtures/mcp-golden');
const runtimeDir = resolve(repoRoot, 'tests/fixtures/mcp-runtime');
const swiftRegistryPath = resolve(
  repoRoot,
  'macos/EngramMCP/Core/MCPToolRegistry.swift',
);
const swiftStdioServerPath = resolve(
  repoRoot,
  'macos/EngramMCP/Core/MCPStdioServer.swift',
);
const linkTargetDir = resolve(runtimeDir, 'engram');
const reviewHomeDir = resolve(runtimeDir, 'review-home');
const transcriptDir = resolve(runtimeDir, 'transcripts');
const exportHomeDir = resolve(runtimeDir, 'export-home');

rmSync(fixtureDbPath, { force: true });
rmSync(`${fixtureDbPath}-wal`, { force: true });
rmSync(`${fixtureDbPath}-shm`, { force: true });
rmSync(linkTargetDir, { recursive: true, force: true });
rmSync(transcriptDir, { recursive: true, force: true });
rmSync(exportHomeDir, { recursive: true, force: true });
mkdirSync(goldenDir, { recursive: true });
mkdirSync(runtimeDir, { recursive: true });
mkdirSync(transcriptDir, { recursive: true });
mkdirSync(exportHomeDir, { recursive: true });
writeFileSync(resolve(exportHomeDir, '.gitkeep'), '');

const db = new Database(fixtureDbPath);
const raw = db.raw;
raw.pragma('journal_mode = DELETE');

const insertSession = raw.prepare(`
  INSERT INTO sessions (
    id, source, start_time, end_time, cwd, project, model,
    message_count, user_message_count, assistant_message_count,
    tool_message_count, system_message_count, summary,
    instruction_count, human_turn_count, instruction_summary, file_path,
    size_bytes, indexed_at, agent_role, origin, tier, generated_title,
    quality_score
  ) VALUES (
    @id, @source, @startTime, @endTime, @cwd, @project, @model,
    @messageCount, @userMessageCount, @assistantMessageCount,
    @toolMessageCount, @systemMessageCount, @summary,
    @instructionCount, @humanTurnCount, @instructionSummary, @filePath,
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
      instructionCount: 2,
      humanTurnCount: 7 + (sessionIndex % 4),
      instructionSummary: `${project.name} asks about the Swift MCP contract`,
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
raw
  .prepare('UPDATE project_aliases SET created_at = ?')
  .run('2026-02-01T09:00:00.000Z');

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

const transcriptPath = resolve(
  transcriptDir,
  'rollout-mcp-transcript-01.jsonl',
);
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
        content: [
          { text: 'Use the Swift EngramMCP helper as the MCP entry point.' },
        ],
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
  instructionCount: 2,
  humanTurnCount: 2,
  instructionSummary: 'Summarize and implement the Swift MCP shim scope',
  filePath:
    '/Users/test/work/transcript-fixture/rollout-mcp-transcript-01.jsonl',
  sizeBytes: 2048,
  indexedAt: '2026-01-15T09:06:00.000Z',
  agentRole: null,
  origin: 'local',
  tier: 'normal',
  generatedTitle: null,
  qualityScore: 55,
});

const linkedSessions = raw
  .prepare(
    `SELECT id, source, file_path AS filePath
     FROM sessions
     WHERE project = ?
     ORDER BY source, id`,
  )
  .all('engram') as Array<{ id: string; source: string; filePath: string }>;
for (const session of linkedSessions) {
  const sourceDir = resolve(linkTargetDir, 'conversation_log', session.source);
  mkdirSync(sourceDir, { recursive: true });
  symlinkSync(session.filePath, resolve(sourceDir, `${session.id}.jsonl`));
}

writeFileSync(
  resolve(goldenDir, 'initialize.result.json'),
  `${JSON.stringify(extractInitializeResultFromSwiftServer(), null, 2)}\n`,
);

writeFileSync(
  resolve(goldenDir, 'tools.json'),
  `${JSON.stringify(extractToolNamesFromSwiftRegistry(), null, 2)}\n`,
);

writeFileSync(
  resolve(goldenDir, 'README.md'),
  [
    '# MCP Golden Fixtures',
    '',
    '`initialize.result.json` and `tools.json` are generated from the native Swift MCP source by `npm run generate:mcp-contract-fixtures`.',
    'All other JSON files are executable behavior snapshots owned by `EngramMCPExecutableTests`; the retired TypeScript handlers must not overwrite them.',
    '',
    'Normalization rules:',
    '- executable snapshots normalize random UUIDs and absolute fixture roots in the Swift test harness',
    '- generated fixture timestamps come from fixed rows, not `now()`',
    '- fixture DB is `tests/fixtures/mcp-contract.sqlite`; never use `~/.engram/index.sqlite` in contract tests',
    '',
  ].join('\n'),
);

// VACUUM rewrites the DB into a stable page layout so CI's byte-level
// `git diff` on mcp-contract.sqlite does not flap across regenerations that
// leave identical logical rows with different free-list / overflow layout.
raw.exec('VACUUM');
db.close();

console.log(`Generated ${fixtureDbPath}`);
console.log(`Generated goldens in ${goldenDir}`);

function extractToolNamesFromSwiftRegistry(): string[] {
  const registrySource = readFileSync(swiftRegistryPath, 'utf8');
  const unavailableTools = extractSwiftStringSet(
    registrySource,
    'unavailableNativeProjectOperationTools',
  );
  const toolNames = [
    ...registrySource.matchAll(/MCPToolDefinition\(\s*name:\s*"([^"]+)"/g),
  ]
    .map((match) => match[1])
    .filter((toolName) => !unavailableTools.has(toolName));
  return [...new Set(toolNames)];
}

function extractInitializeResultFromSwiftServer(): Record<string, unknown> {
  const serverSource = readFileSync(swiftStdioServerPath, 'utf8');
  const instructionsMatch = serverSource.match(
    /private static let instructions = """\n([\s\S]*?)\n {4}"""/,
  );

  if (!instructionsMatch) {
    throw new Error(
      `Unable to locate instructions multiline string in ${swiftStdioServerPath}`,
    );
  }

  return {
    protocolVersion: '2025-03-26',
    capabilities: { tools: {}, resources: {}, prompts: {} },
    serverInfo: { name: 'engram', version: '0.1.0' },
    instructions: normalizeSwiftMultilineString(instructionsMatch[1]),
  };
}

function extractSwiftStringSet(source: string, name: string): Set<string> {
  const match = source.match(
    new RegExp(
      String.raw`private static let ${name}:\s*Set<String>\s*=\s*\[([\s\S]*?)\]`,
    ),
  );
  if (!match) return new Set();
  return new Set([...match[1].matchAll(/"([^"]+)"/g)].map((item) => item[1]));
}

function normalizeSwiftMultilineString(value: string): string {
  return value
    .split('\n')
    .map((line) => line.replace(/^ {4}/, ''))
    .join('\n');
}
