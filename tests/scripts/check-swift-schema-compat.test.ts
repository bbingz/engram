import { execFileSync } from 'node:child_process';
import {
  chmodSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { afterEach, describe, expect, it } from 'vitest';

const repoRoot = resolve(import.meta.dirname, '../..');

describe('check-swift-schema-compat', () => {
  let tmp = '';

  afterEach(() => {
    if (tmp) rmSync(tmp, { recursive: true, force: true });
  });

  it('uses a Swift schema tool and proves Node can read fresh and migrated databases', () => {
    tmp = mkdtempSync(join(tmpdir(), 'engram-swift-schema-compat-test-'));
    const fixtureRoot = join(tmp, 'fixtures');
    const callsPath = join(tmp, 'calls.jsonl');
    const fakeTool = join(tmp, 'fake-swift-schema-tool.mjs');
    writeFileSync(
      fakeTool,
      `#!/usr/bin/env node
import Database from ${JSON.stringify(resolve(repoRoot, 'node_modules/better-sqlite3/lib/index.js'))};
import { appendFileSync } from 'node:fs';
const [, , command, dbPath] = process.argv;
appendFileSync(${JSON.stringify(callsPath)}, JSON.stringify({ command, dbPath }) + '\\n');
const db = new Database(dbPath);
db.exec(\`
  CREATE TABLE IF NOT EXISTS sessions (
    id TEXT PRIMARY KEY,
    source TEXT NOT NULL,
    start_time TEXT NOT NULL,
    end_time TEXT,
    cwd TEXT NOT NULL DEFAULT '',
    project TEXT,
    model TEXT,
    message_count INTEGER NOT NULL DEFAULT 0,
    user_message_count INTEGER NOT NULL DEFAULT 0,
    assistant_message_count INTEGER NOT NULL DEFAULT 0,
    tool_message_count INTEGER NOT NULL DEFAULT 0,
    system_message_count INTEGER NOT NULL DEFAULT 0,
    summary TEXT,
    summary_message_count INTEGER,
    file_path TEXT NOT NULL,
    size_bytes INTEGER NOT NULL DEFAULT 0,
    indexed_at TEXT NOT NULL DEFAULT '',
    agent_role TEXT,
    hidden_at TEXT,
    custom_name TEXT,
    origin TEXT DEFAULT 'local',
    authoritative_node TEXT,
    source_locator TEXT,
    sync_version INTEGER NOT NULL DEFAULT 0,
    snapshot_hash TEXT,
    tier TEXT,
    generated_title TEXT,
    quality_score INTEGER DEFAULT 0,
    parent_session_id TEXT,
    suggested_parent_id TEXT,
    link_source TEXT,
    link_checked_at TEXT,
    orphan_status TEXT,
    orphan_since TEXT,
    orphan_reason TEXT
  );
\`);
const existing = new Set(db.prepare('PRAGMA table_info(sessions)').all().map((row) => row.name));
const columns = [
  ['end_time', 'TEXT'],
  ['project', 'TEXT'],
  ['model', 'TEXT'],
  ['message_count', 'INTEGER NOT NULL DEFAULT 0'],
  ['user_message_count', 'INTEGER NOT NULL DEFAULT 0'],
  ['assistant_message_count', 'INTEGER NOT NULL DEFAULT 0'],
  ['tool_message_count', 'INTEGER NOT NULL DEFAULT 0'],
  ['system_message_count', 'INTEGER NOT NULL DEFAULT 0'],
  ['summary', 'TEXT'],
  ['summary_message_count', 'INTEGER'],
  ['size_bytes', 'INTEGER NOT NULL DEFAULT 0'],
  ['indexed_at', "TEXT NOT NULL DEFAULT ''"],
  ['agent_role', 'TEXT'],
  ['hidden_at', 'TEXT'],
  ['custom_name', 'TEXT'],
  ['origin', "TEXT DEFAULT 'local'"],
  ['authoritative_node', 'TEXT'],
  ['source_locator', 'TEXT'],
  ['sync_version', 'INTEGER NOT NULL DEFAULT 0'],
  ['snapshot_hash', 'TEXT'],
  ['tier', 'TEXT'],
  ['generated_title', 'TEXT'],
  ['quality_score', 'INTEGER DEFAULT 0'],
  ['parent_session_id', 'TEXT'],
  ['suggested_parent_id', 'TEXT'],
  ['link_source', 'TEXT'],
  ['link_checked_at', 'TEXT'],
  ['orphan_status', 'TEXT'],
  ['orphan_since', 'TEXT'],
  ['orphan_reason', 'TEXT'],
];
for (const [name, definition] of columns) {
  if (!existing.has(name)) db.exec(\`ALTER TABLE sessions ADD COLUMN \${name} \${definition}\`);
}
db.exec(\`
  CREATE VIRTUAL TABLE IF NOT EXISTS sessions_fts USING fts5(session_id UNINDEXED, content);
  CREATE TABLE IF NOT EXISTS metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL);
  INSERT INTO metadata(key, value) VALUES ('schema_version', '1')
    ON CONFLICT(key) DO UPDATE SET value = excluded.value;
  INSERT INTO metadata(key, value) VALUES ('fts_version', '3')
    ON CONFLICT(key) DO UPDATE SET value = excluded.value;
\`);
db.close();
`,
    );
    chmodSync(fakeTool, 0o755);

    const output = execFileSync(
      './node_modules/.bin/tsx',
      [
        'scripts/db/check-swift-schema-compat.ts',
        '--fixture-root',
        fixtureRoot,
        '--schema-tool',
        fakeTool,
        '--skip-build',
      ],
      { cwd: repoRoot, encoding: 'utf8' },
    );

    const calls = readFileSync(callsPath, 'utf8')
      .trim()
      .split('\n')
      .map((line) => JSON.parse(line) as { command: string; dbPath: string });
    expect(output).toContain('swift schema compatibility ok');
    expect(calls.map((call) => call.command)).toEqual(['migrate', 'migrate']);
    expect(calls.every((call) => call.dbPath.startsWith(fixtureRoot))).toBe(
      true,
    );
  }, 20_000);
});
