#!/usr/bin/env tsx
import { existsSync, unlinkSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
/**
 * Generate deterministic test fixture DB with 20 seed sessions.
 * Run: npm run generate:fixtures
 */
import { Database } from '../src/core/db.js';

const __dirname = dirname(fileURLToPath(import.meta.url));
const fixturePath = resolve(__dirname, '../test-fixtures/test-index.sqlite');

// Remove existing fixture for clean generation
if (existsSync(fixturePath)) {
  unlinkSync(fixturePath);
}

// Create DB via Database class (runs migrate(), sets up schema + metadata)
const db = new Database(fixturePath);
const raw = db.getRawDb();

// Switch to DELETE journal mode for single-file determinism
raw.pragma('journal_mode = DELETE');

// ─── Session seed data ───────────────────────────────────────────────
const insertSession = raw.prepare(`
  INSERT INTO sessions (
    id, source, start_time, end_time, cwd, project, model,
    message_count, user_message_count, assistant_message_count,
    tool_message_count, system_message_count,
    summary, file_path, size_bytes, indexed_at,
    agent_role, origin, tier, generated_title, quality_score
  ) VALUES (
    @id, @source, @startTime, @endTime, @cwd, @project, @model,
    @messageCount, @userMessageCount, @assistantMessageCount,
    @toolMessageCount, @systemMessageCount,
    @summary, @filePath, @sizeBytes, @indexedAt,
    @agentRole, @origin, @tier, @generatedTitle, @qualityScore
  )
`);

interface SeedSession {
  id: string;
  source: string;
  startTime: string;
  endTime: string | null;
  cwd: string;
  project: string | null;
  model: string;
  messageCount: number;
  userMessageCount: number;
  assistantMessageCount: number;
  toolMessageCount: number;
  systemMessageCount: number;
  summary: string | null;
  filePath: string;
  sizeBytes: number;
  indexedAt: string;
  agentRole: string | null;
  origin: string;
  tier: string;
  generatedTitle: string | null;
  qualityScore: number;
}

const sessions: SeedSession[] = [
  // 1: Standard claude-code, engram project
  {
    id: 'seed-01',
    source: 'claude-code',
    startTime: '2026-01-15T10:00:00.000Z',
    endTime: '2026-01-15T11:00:00.000Z',
    cwd: '/Users/test/engram',
    project: 'engram',
    model: 'claude-sonnet-4-20250514',
    messageCount: 15,
    userMessageCount: 8,
    assistantMessageCount: 5,
    toolMessageCount: 2,
    systemMessageCount: 0,
    summary: 'Refactored adapter pipeline for performance',
    filePath: 'sessions/seed-01.jsonl',
    sizeBytes: 25000,
    indexedAt: '2026-01-15T11:05:00.000Z',
    agentRole: null,
    origin: 'local',
    tier: 'normal',
    generatedTitle: null,
    qualityScore: 65,
  },
  // 2: Standard claude-code, my-app project
  {
    id: 'seed-02',
    source: 'claude-code',
    startTime: '2026-01-15T12:00:00.000Z',
    endTime: '2026-01-15T13:00:00.000Z',
    cwd: '/Users/test/my-app',
    project: 'my-app',
    model: 'claude-sonnet-4-20250514',
    messageCount: 12,
    userMessageCount: 6,
    assistantMessageCount: 4,
    toolMessageCount: 2,
    systemMessageCount: 0,
    summary: 'Fixed authentication flow bug',
    filePath: 'sessions/seed-02.jsonl',
    sizeBytes: 18000,
    indexedAt: '2026-01-15T13:05:00.000Z',
    agentRole: null,
    origin: 'local',
    tier: 'normal',
    generatedTitle: null,
    qualityScore: 55,
  },
  // 3: Cursor, engram project
  {
    id: 'seed-03',
    source: 'cursor',
    startTime: '2026-01-16T09:00:00.000Z',
    endTime: '2026-01-16T10:30:00.000Z',
    cwd: '/Users/test/engram',
    project: 'engram',
    model: 'gpt-4o',
    messageCount: 20,
    userMessageCount: 10,
    assistantMessageCount: 8,
    toolMessageCount: 2,
    systemMessageCount: 0,
    summary: 'Added dark mode support to UI components',
    filePath: '/Users/test/.cursor/sessions/seed-03.json',
    sizeBytes: 32000,
    indexedAt: '2026-01-16T10:35:00.000Z',
    agentRole: null,
    origin: 'local',
    tier: 'normal',
    generatedTitle: null,
    qualityScore: 70,
  },
  // 4: Cursor, my-app project
  {
    id: 'seed-04',
    source: 'cursor',
    startTime: '2026-01-16T14:00:00.000Z',
    endTime: '2026-01-16T15:00:00.000Z',
    cwd: '/Users/test/my-app',
    project: 'my-app',
    model: 'gpt-4o',
    messageCount: 8,
    userMessageCount: 4,
    assistantMessageCount: 3,
    toolMessageCount: 1,
    systemMessageCount: 0,
    summary: 'Set up CI/CD pipeline configuration',
    filePath: '/Users/test/.cursor/sessions/seed-04.json',
    sizeBytes: 12000,
    indexedAt: '2026-01-16T15:05:00.000Z',
    agentRole: null,
    origin: 'local',
    tier: 'normal',
    generatedTitle: null,
    qualityScore: 45,
  },
  // 5: Codex, lite tier, low messages
  {
    id: 'seed-05',
    source: 'codex',
    startTime: '2026-01-17T08:00:00.000Z',
    endTime: '2026-01-17T08:10:00.000Z',
    cwd: '/Users/test/test-lib',
    project: 'test-lib',
    model: 'codex-1',
    messageCount: 2,
    userMessageCount: 1,
    assistantMessageCount: 1,
    toolMessageCount: 0,
    systemMessageCount: 0,
    summary: 'Quick lint fix',
    filePath: 'sessions/seed-05.jsonl',
    sizeBytes: 2000,
    indexedAt: '2026-01-17T08:15:00.000Z',
    agentRole: null,
    origin: 'local',
    tier: 'lite',
    generatedTitle: null,
    qualityScore: 10,
  },
  // 6: Codex, lite tier, low messages
  {
    id: 'seed-06',
    source: 'codex',
    startTime: '2026-01-17T09:00:00.000Z',
    endTime: '2026-01-17T09:15:00.000Z',
    cwd: '/Users/test/utils',
    project: 'utils',
    model: 'codex-1',
    messageCount: 3,
    userMessageCount: 2,
    assistantMessageCount: 1,
    toolMessageCount: 0,
    systemMessageCount: 0,
    summary: 'Updated README',
    filePath: 'sessions/seed-06.jsonl',
    sizeBytes: 3000,
    indexedAt: '2026-01-17T09:20:00.000Z',
    agentRole: null,
    origin: 'local',
    tier: 'lite',
    generatedTitle: null,
    qualityScore: 15,
  },
  // 7: Gemini, premium tier with generated_title + summary
  {
    id: 'seed-07',
    source: 'gemini-cli',
    startTime: '2026-01-18T10:00:00.000Z',
    endTime: '2026-01-18T12:00:00.000Z',
    cwd: '/Users/test/engram',
    project: 'engram',
    model: 'gemini-2.0-flash',
    messageCount: 30,
    userMessageCount: 15,
    assistantMessageCount: 12,
    toolMessageCount: 3,
    systemMessageCount: 0,
    summary:
      'Implemented full local semantic index integration with fallback support',
    filePath: 'sessions/seed-07.json',
    sizeBytes: 60000,
    indexedAt: '2026-01-18T12:05:00.000Z',
    agentRole: null,
    origin: 'local',
    tier: 'premium',
    generatedTitle: 'Local Semantic Index Integration',
    qualityScore: 90,
  },
  // 8: Windsurf, long summary (2000 chars)
  {
    id: 'seed-08',
    source: 'windsurf',
    startTime: '2026-01-19T08:00:00.000Z',
    endTime: '2026-01-19T10:00:00.000Z',
    cwd: '/Users/test/big-proj',
    project: 'big-proj',
    model: 'claude-sonnet-4-20250514',
    messageCount: 25,
    userMessageCount: 12,
    assistantMessageCount: 10,
    toolMessageCount: 3,
    systemMessageCount: 0,
    summary: `${'This is a very long summary that describes a complex refactoring session. '.repeat(
      25,
    )}End of summary.`,
    filePath: 'sessions/seed-08.jsonl',
    sizeBytes: 45000,
    indexedAt: '2026-01-19T10:05:00.000Z',
    agentRole: null,
    origin: 'local',
    tier: 'normal',
    generatedTitle: null,
    qualityScore: 60,
  },
  // 9: Cline, CJK content
  {
    id: 'seed-09',
    source: 'cline',
    startTime: '2026-01-20T06:00:00.000Z',
    endTime: '2026-01-20T07:00:00.000Z',
    cwd: '/Users/test/zhongwen',
    project: 'zhongwen',
    model: 'claude-sonnet-4-20250514',
    messageCount: 10,
    userMessageCount: 5,
    assistantMessageCount: 4,
    toolMessageCount: 1,
    systemMessageCount: 0,
    summary: '修復了認證模組的問題。テストケースを追加しました。',
    filePath: 'sessions/seed-09.json',
    sizeBytes: 15000,
    indexedAt: '2026-01-20T07:05:00.000Z',
    agentRole: null,
    origin: 'local',
    tier: 'normal',
    generatedTitle: null,
    qualityScore: 50,
  },
  // 10: Skip tier, agent subprocess
  {
    id: 'seed-10',
    source: 'claude-code',
    startTime: '2026-01-15T10:30:00.000Z',
    endTime: '2026-01-15T10:45:00.000Z',
    cwd: '/Users/test/engram',
    project: 'engram',
    model: 'claude-sonnet-4-20250514',
    messageCount: 5,
    userMessageCount: 2,
    assistantMessageCount: 2,
    toolMessageCount: 1,
    systemMessageCount: 0,
    summary: 'Subagent: file search task',
    filePath: 'sessions/seed-10.jsonl',
    sizeBytes: 5000,
    indexedAt: '2026-01-15T10:50:00.000Z',
    agentRole: 'subagent',
    origin: 'local',
    tier: 'skip',
    generatedTitle: null,
    qualityScore: 0,
  },
  // 11: Cursor, premium, high message count
  {
    id: 'seed-11',
    source: 'cursor',
    startTime: '2026-01-21T09:00:00.000Z',
    endTime: '2026-01-21T14:00:00.000Z',
    cwd: '/Users/test/engram',
    project: 'engram',
    model: 'gpt-4o',
    messageCount: 100,
    userMessageCount: 50,
    assistantMessageCount: 40,
    toolMessageCount: 10,
    systemMessageCount: 0,
    summary:
      'Major refactor of the entire search subsystem with FTS5 trigram support',
    filePath: '/Users/test/.cursor/sessions/seed-11.json',
    sizeBytes: 150000,
    indexedAt: '2026-01-21T14:05:00.000Z',
    agentRole: null,
    origin: 'local',
    tier: 'premium',
    generatedTitle: 'Search Subsystem Refactor',
    qualityScore: 95,
  },
  // 12: Empty string project
  {
    id: 'seed-12',
    source: 'codex',
    startTime: '2026-01-22T10:00:00.000Z',
    endTime: '2026-01-22T10:30:00.000Z',
    cwd: '/Users/test/unknown',
    project: '',
    model: 'codex-1',
    messageCount: 6,
    userMessageCount: 3,
    assistantMessageCount: 3,
    toolMessageCount: 0,
    systemMessageCount: 0,
    summary: 'Ad-hoc debugging session without project context',
    filePath: 'sessions/seed-12.jsonl',
    sizeBytes: 8000,
    indexedAt: '2026-01-22T10:35:00.000Z',
    agentRole: null,
    origin: 'local',
    tier: 'normal',
    generatedTitle: null,
    qualityScore: 30,
  },
  // 13: Null summary, null end_time
  {
    id: 'seed-13',
    source: 'claude-code',
    startTime: '2026-01-23T15:00:00.000Z',
    endTime: null,
    cwd: '/Users/test/engram',
    project: 'engram',
    model: 'claude-sonnet-4-20250514',
    messageCount: 7,
    userMessageCount: 4,
    assistantMessageCount: 3,
    toolMessageCount: 0,
    systemMessageCount: 0,
    summary: null,
    filePath: 'sessions/seed-13.jsonl',
    sizeBytes: 10000,
    indexedAt: '2026-01-23T15:05:00.000Z',
    agentRole: null,
    origin: 'local',
    tier: 'normal',
    generatedTitle: null,
    qualityScore: 35,
  },
  // 14: Zero messages
  {
    id: 'seed-14',
    source: 'gemini-cli',
    startTime: '2026-01-24T08:00:00.000Z',
    endTime: '2026-01-24T08:01:00.000Z',
    cwd: '/Users/test/engram',
    project: 'engram',
    model: 'gemini-2.0-flash',
    messageCount: 0,
    userMessageCount: 0,
    assistantMessageCount: 0,
    toolMessageCount: 0,
    systemMessageCount: 0,
    summary: null,
    filePath: 'sessions/seed-14.json',
    sizeBytes: 500,
    indexedAt: '2026-01-24T08:05:00.000Z',
    agentRole: null,
    origin: 'local',
    tier: 'normal',
    generatedTitle: null,
    qualityScore: 0,
  },
  // 15: start_time == end_time
  {
    id: 'seed-15',
    source: 'claude-code',
    startTime: '2026-01-25T12:00:00.000Z',
    endTime: '2026-01-25T12:00:00.000Z',
    cwd: '/Users/test/engram',
    project: 'engram',
    model: 'claude-sonnet-4-20250514',
    messageCount: 4,
    userMessageCount: 2,
    assistantMessageCount: 2,
    toolMessageCount: 0,
    systemMessageCount: 0,
    summary: 'Instant session with zero duration',
    filePath: 'sessions/seed-15.jsonl',
    sizeBytes: 4000,
    indexedAt: '2026-01-25T12:05:00.000Z',
    agentRole: null,
    origin: 'local',
    tier: 'normal',
    generatedTitle: null,
    qualityScore: 20,
  },
  // 16: Null project, lite tier
  {
    id: 'seed-16',
    source: 'cursor',
    startTime: '2026-01-26T16:00:00.000Z',
    endTime: '2026-01-26T16:30:00.000Z',
    cwd: '/tmp/scratch',
    project: null,
    model: 'gpt-4o',
    messageCount: 5,
    userMessageCount: 3,
    assistantMessageCount: 2,
    toolMessageCount: 0,
    systemMessageCount: 0,
    summary: 'Scratch session with no project',
    filePath: '/Users/test/.cursor/sessions/seed-16.json',
    sizeBytes: 6000,
    indexedAt: '2026-01-26T16:35:00.000Z',
    agentRole: null,
    origin: 'local',
    tier: 'lite',
    generatedTitle: null,
    qualityScore: 15,
  },
  // 17: Skip tier, hidden session
  {
    id: 'seed-17',
    source: 'windsurf',
    startTime: '2026-01-10T08:00:00.000Z',
    endTime: '2026-01-10T09:00:00.000Z',
    cwd: '/Users/test/old-proj',
    project: 'old-proj',
    model: 'claude-sonnet-4-20250514',
    messageCount: 8,
    userMessageCount: 4,
    assistantMessageCount: 3,
    toolMessageCount: 1,
    systemMessageCount: 0,
    summary: 'Old session that was hidden by user',
    filePath: 'sessions/seed-17.jsonl',
    sizeBytes: 11000,
    indexedAt: '2026-01-10T09:05:00.000Z',
    agentRole: null,
    origin: 'local',
    tier: 'skip',
    generatedTitle: null,
    qualityScore: 0,
  },
  // 18: Custom name
  {
    id: 'seed-18',
    source: 'cline',
    startTime: '2026-01-27T11:00:00.000Z',
    endTime: '2026-01-27T12:00:00.000Z',
    cwd: '/Users/test/engram',
    project: 'engram',
    model: 'claude-sonnet-4-20250514',
    messageCount: 14,
    userMessageCount: 7,
    assistantMessageCount: 5,
    toolMessageCount: 2,
    systemMessageCount: 0,
    summary: 'Database migration and schema updates',
    filePath: 'sessions/seed-18.json',
    sizeBytes: 20000,
    indexedAt: '2026-01-27T12:05:00.000Z',
    agentRole: null,
    origin: 'local',
    tier: 'normal',
    generatedTitle: null,
    qualityScore: 60,
  },
  // 19: Very old session (2025)
  {
    id: 'seed-19',
    source: 'claude-code',
    startTime: '2025-01-01T00:00:00.000Z',
    endTime: '2025-01-01T01:00:00.000Z',
    cwd: '/Users/test/legacy',
    project: 'legacy',
    model: 'claude-3-opus',
    messageCount: 10,
    userMessageCount: 5,
    assistantMessageCount: 4,
    toolMessageCount: 1,
    systemMessageCount: 0,
    summary: 'Legacy session from early 2025',
    filePath: 'sessions/seed-19.jsonl',
    sizeBytes: 14000,
    indexedAt: '2025-01-01T01:05:00.000Z',
    agentRole: null,
    origin: 'local',
    tier: 'normal',
    generatedTitle: null,
    qualityScore: 40,
  },
  // 20: Max tool_message_count
  {
    id: 'seed-20',
    source: 'codex',
    startTime: '2026-01-28T14:00:00.000Z',
    endTime: '2026-01-28T16:00:00.000Z',
    cwd: '/Users/test/engram',
    project: 'engram',
    model: 'codex-1',
    messageCount: 80,
    userMessageCount: 15,
    assistantMessageCount: 15,
    toolMessageCount: 50,
    systemMessageCount: 0,
    summary: 'Heavy tool usage session with many file operations',
    filePath: 'sessions/seed-20.jsonl',
    sizeBytes: 120000,
    indexedAt: '2026-01-28T16:05:00.000Z',
    agentRole: null,
    origin: 'local',
    tier: 'normal',
    generatedTitle: null,
    qualityScore: 75,
  },
];

// Insert all sessions using raw SQL for deterministic indexed_at
const insertAll = raw.transaction(() => {
  for (const s of sessions) {
    insertSession.run(s);
  }
});
insertAll();

// ─── session_local_state entries ──────────────────────────────────────
// seed-17: hidden session
raw
  .prepare(`
  INSERT INTO session_local_state (session_id, hidden_at)
  VALUES ('seed-17', '2026-02-01T00:00:00.000Z')
`)
  .run();

// seed-18: custom name
raw
  .prepare(`
  INSERT INTO session_local_state (session_id, custom_name)
  VALUES ('seed-18', 'My Custom Session')
`)
  .run();

// ─── Favorites (Swift extension table) ───────────────────────────────
raw.exec(`
  CREATE TABLE IF NOT EXISTS favorites (
    session_id TEXT PRIMARY KEY,
    created_at TEXT NOT NULL
  );
`);

raw
  .prepare(`INSERT INTO favorites (session_id, created_at) VALUES (?, ?)`)
  .run('seed-01', '2026-01-15T11:10:00.000Z');
raw
  .prepare(`INSERT INTO favorites (session_id, created_at) VALUES (?, ?)`)
  .run('seed-07', '2026-01-18T12:10:00.000Z');
raw
  .prepare(`INSERT INTO favorites (session_id, created_at) VALUES (?, ?)`)
  .run('seed-11', '2026-01-21T14:10:00.000Z');

// ─── Tags (Swift extension table) ────────────────────────────────────
raw.exec(`
  CREATE TABLE IF NOT EXISTS tags (
    session_id TEXT NOT NULL,
    tag        TEXT NOT NULL,
    created_at TEXT NOT NULL,
    PRIMARY KEY (session_id, tag)
  );
`);

const insertTag = raw.prepare(
  `INSERT INTO tags (session_id, tag, created_at) VALUES (?, ?, ?)`,
);
insertTag.run('seed-01', 'important', '2026-01-15T11:10:00.000Z');
insertTag.run('seed-01', 'review', '2026-01-15T11:10:00.000Z');
insertTag.run('seed-03', 'bug', '2026-01-16T10:35:00.000Z');
insertTag.run('seed-07', 'premium', '2026-01-18T12:10:00.000Z');
insertTag.run('seed-09', 'cjk', '2026-01-20T07:05:00.000Z');

// ─── Git repos ──────────────────────────────────────────────────────
const insertRepo = raw.prepare(`
  INSERT INTO git_repos (path, name, branch, last_commit_hash, last_commit_at, session_count)
  VALUES (?, ?, ?, ?, ?, ?)
`);
insertRepo.run(
  '/Users/dev/project-alpha',
  'project-alpha',
  'main',
  'abc1234',
  '2026-01-14T10:00:00Z',
  8,
);
insertRepo.run(
  '/Users/dev/project-beta',
  'project-beta',
  'develop',
  'def5678',
  '2026-01-15T08:00:00Z',
  5,
);
insertRepo.run(
  '/Users/dev/engram',
  'engram',
  'main',
  'ghi9012',
  '2026-01-15T09:30:00Z',
  12,
);

// ─── Logs (source must be 'daemon' or 'app' — CHECK constraint) ─────
const insertLog = raw.prepare(`
  INSERT INTO logs (level, module, message, ts, source)
  VALUES (?, ?, ?, ?, ?)
`);
insertLog.run(
  'info',
  'indexer',
  'Session started',
  '2026-01-15T10:00:00Z',
  'daemon',
);
insertLog.run(
  'debug',
  'indexer',
  'Indexing 5 files',
  '2026-01-15T10:00:01Z',
  'daemon',
);
insertLog.run(
  'warn',
  'db',
  'Slow query detected',
  '2026-01-14T09:00:00Z',
  'daemon',
);
insertLog.run(
  'error',
  'daemon',
  'Connection refused',
  '2026-01-13T14:00:00Z',
  'daemon',
);
insertLog.run(
  'info',
  'semantic_index',
  'Semantic index sync complete',
  '2026-01-12T11:00:00Z',
  'daemon',
);

// ─── Traces (source must be 'daemon' or 'app') ─────────────────────
const insertTrace = raw.prepare(`
  INSERT INTO traces (trace_id, span_id, name, module, start_ts, end_ts, duration_ms, status, source)
  VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
`);
insertTrace.run(
  't1',
  's1',
  'index_session',
  'indexer',
  '2026-01-15T10:00:00Z',
  '2026-01-15T10:00:02Z',
  2000,
  'ok',
  'daemon',
);
insertTrace.run(
  't2',
  's2',
  'fts_search',
  'search',
  '2026-01-14T09:00:01Z',
  '2026-01-14T09:00:01Z',
  150,
  'ok',
  'daemon',
);
insertTrace.run(
  't3',
  's3',
  'embedding_index',
  'semantic_index',
  '2026-01-13T14:00:00Z',
  '2026-01-13T14:00:05Z',
  5000,
  'error',
  'daemon',
);

// ─── Metrics (type must be 'counter', 'gauge', or 'histogram') ─────
const insertMetric = raw.prepare(`
  INSERT INTO metrics (name, type, value, tags, ts)
  VALUES (?, ?, ?, ?, ?)
`);
insertMetric.run(
  'index_duration_ms',
  'gauge',
  2000,
  '{"source":"claude-code"}',
  '2026-01-15T10:00:02Z',
);
insertMetric.run(
  'messages_indexed',
  'counter',
  45,
  '{"source":"claude-code"}',
  '2026-01-15T10:00:02Z',
);
insertMetric.run(
  'search_latency_ms',
  'gauge',
  150,
  '{}',
  '2026-01-14T09:00:01Z',
);
insertMetric.run(
  'embedding_index_ms',
  'gauge',
  5000,
  '{}',
  '2026-01-13T14:00:05Z',
);
insertMetric.run('sessions_synced', 'counter', 3, '{}', '2026-01-12T11:00:00Z');

db.close();

console.log(`Generated fixture DB at ${fixturePath}`);
console.log(`  Sessions: ${sessions.length}`);
console.log(`  Favorites: 3`);
console.log(`  Tags: 5`);
console.log(`  Git repos: 3`);
console.log(`  Logs: 5`);
console.log(`  Traces: 3`);
console.log(`  Metrics: 5`);
