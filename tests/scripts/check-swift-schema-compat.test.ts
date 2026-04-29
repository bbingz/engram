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
import { pathToFileURL } from 'node:url';
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
import { execFileSync } from 'node:child_process';
import { appendFileSync } from 'node:fs';
const [, , command, dbPath] = process.argv;
appendFileSync(${JSON.stringify(callsPath)}, JSON.stringify({ command, dbPath }) + '\\n');
const dbModuleUrl = ${JSON.stringify(pathToFileURL(resolve(repoRoot, 'src/core/db.ts')).href)};
const memoryInsightsSql = "CREATE TABLE IF NOT EXISTS memory_insights (id TEXT PRIMARY KEY, content TEXT NOT NULL, wing TEXT, room TEXT, source_session_id TEXT, importance INTEGER DEFAULT 5, model TEXT NOT NULL DEFAULT 'unknown', created_at TEXT DEFAULT (datetime('now')), deleted_at TEXT);";
const script = [
  "import BetterSqlite3 from 'better-sqlite3';",
  "async function main() {",
  "const { Database: EngramDatabase } = await import(" + JSON.stringify(dbModuleUrl) + ");",
  "const dbPath = process.env.ENGRAM_SCHEMA_DB_PATH;",
  "if (!dbPath) throw new Error('ENGRAM_SCHEMA_DB_PATH is required');",
  "const db = new EngramDatabase(dbPath);",
  "db.close();",
  "const raw = new BetterSqlite3(dbPath);",
  "try { raw.exec(" + JSON.stringify(memoryInsightsSql) + "); }",
  "finally { raw.close(); }",
  "}",
  "main().catch((error) => { console.error(error); process.exit(1); });",
].join('\\n');
execFileSync('./node_modules/.bin/tsx', ['-e', script], {
  cwd: ${JSON.stringify(repoRoot)},
  env: { ...process.env, ENGRAM_SCHEMA_DB_PATH: dbPath },
  stdio: 'pipe',
});
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
  }, 60_000);
});
