#!/usr/bin/env tsx
import { execFileSync } from 'node:child_process';
import { accessSync, mkdirSync, mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import BetterSqlite3 from 'better-sqlite3';
import { Database as EngramDatabase } from '../../src/core/db.js';

interface Args {
  fixtureRoot: string;
  schemaTool: string;
  skipBuild: boolean;
}

interface SqliteNameRow {
  name: string;
}

function parseArgs(argv: string[]): Args {
  let fixtureRoot = '';
  let schemaTool = '';
  let skipBuild = false;
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === '--fixture-root') {
      const value = argv[i + 1];
      if (!value) throw new Error('--fixture-root requires a value');
      fixtureRoot = resolve(value);
      i += 1;
      continue;
    }
    if (arg === '--schema-tool') {
      const value = argv[i + 1];
      if (!value) throw new Error('--schema-tool requires a value');
      schemaTool = resolve(value);
      i += 1;
      continue;
    }
    if (arg === '--skip-build') {
      skipBuild = true;
      continue;
    }
    throw new Error(`unknown argument: ${arg}`);
  }
  if (!fixtureRoot) throw new Error('--fixture-root is required');
  return { fixtureRoot, schemaTool, skipBuild };
}

function buildSchemaTool(repoRoot: string, tempRoot: string): string {
  const derivedData = join(tempRoot, 'DerivedData');
  execFileSync(
    'xcodebuild',
    [
      '-project',
      'macos/Engram.xcodeproj',
      '-scheme',
      'EngramCoreSchemaTool',
      '-configuration',
      'Debug',
      '-derivedDataPath',
      derivedData,
      'build',
    ],
    { cwd: repoRoot, stdio: 'pipe' },
  );
  const tool = join(derivedData, 'Build/Products/Debug/EngramCoreSchemaTool');
  accessSync(tool);
  return tool;
}

function prepareLegacyDatabase(dbPath: string): void {
  const db = new BetterSqlite3(dbPath);
  try {
    db.exec(`
      CREATE TABLE sessions (
        id TEXT PRIMARY KEY,
        source TEXT NOT NULL,
        start_time TEXT NOT NULL,
        cwd TEXT NOT NULL DEFAULT '',
        file_path TEXT NOT NULL
      );
      INSERT INTO sessions(id, source, start_time, cwd, file_path)
      VALUES ('legacy-1', 'codex', '2026-01-01T00:00:00.000Z', '/tmp/project', '/tmp/session.jsonl');
    `);
  } finally {
    db.close();
  }
}

function runSwiftMigration(schemaTool: string, dbPath: string): void {
  const frameworkPath = dirname(schemaTool);
  execFileSync(schemaTool, ['migrate', dbPath], {
    stdio: 'pipe',
    env: {
      ...process.env,
      DYLD_FRAMEWORK_PATH: [
        frameworkPath,
        process.env.DYLD_FRAMEWORK_PATH,
      ]
        .filter(Boolean)
        .join(':'),
    },
  });
}

function tableNames(dbPath: string): Set<string> {
  const db = new BetterSqlite3(dbPath, { readonly: true });
  try {
    const rows = db
      .prepare("SELECT name FROM sqlite_master WHERE type = 'table'")
      .all() as SqliteNameRow[];
    return new Set(rows.map((row) => row.name));
  } finally {
    db.close();
  }
}

function metadataValue(dbPath: string, key: string): string | undefined {
  const db = new BetterSqlite3(dbPath, { readonly: true });
  try {
    return db
      .prepare('SELECT value FROM metadata WHERE key = ?')
      .pluck()
      .get(key) as string | undefined;
  } finally {
    db.close();
  }
}

function assertSwiftSchemaBeforeNode(dbPath: string, label: string): void {
  const tables = tableNames(dbPath);
  for (const table of ['sessions', 'sessions_fts', 'metadata']) {
    if (!tables.has(table)) {
      throw new Error(`${label}: missing Swift table before Node open: ${table}`);
    }
  }
  const schemaVersion = metadataValue(dbPath, 'schema_version');
  const ftsVersion = metadataValue(dbPath, 'fts_version');
  if (schemaVersion !== '1') {
    throw new Error(`${label}: expected schema_version=1 before Node open, got ${schemaVersion}`);
  }
  if (ftsVersion !== '3') {
    throw new Error(`${label}: expected fts_version=3 before Node open, got ${ftsVersion}`);
  }
}

function assertNodeCanRead(dbPath: string, label: string): void {
  const db = new EngramDatabase(dbPath);
  try {
    const raw = db.getRawDb();
    const schemaVersion = raw
      .prepare("SELECT value FROM metadata WHERE key = 'schema_version'")
      .pluck()
      .get();
    const ftsVersion = raw
      .prepare("SELECT value FROM metadata WHERE key = 'fts_version'")
      .pluck()
      .get();
    if (schemaVersion !== '1') {
      throw new Error(`${label}: Node read schema_version mismatch: ${schemaVersion}`);
    }
    if (ftsVersion !== '3') {
      throw new Error(`${label}: Node read fts_version mismatch: ${ftsVersion}`);
    }
    raw.prepare('SELECT count(*) FROM sessions').get();
  } finally {
    db.close();
  }
}

function assertLegacyRowPreserved(dbPath: string): void {
  const db = new EngramDatabase(dbPath);
  try {
    const row = db
      .getRawDb()
      .prepare("SELECT id FROM sessions WHERE id = 'legacy-1'")
      .get();
    if (!row) throw new Error('migrated: legacy session row was not preserved');
  } finally {
    db.close();
  }
}

function run(args: Args): void {
  const repoRoot = resolve(import.meta.dirname, '../..');
  mkdirSync(args.fixtureRoot, { recursive: true });
  const tempRoot = mkdtempSync(join(args.fixtureRoot, '.swift-schema-compat-'));
  const buildRoot = mkdtempSync(join(tmpdir(), 'engram-swift-schema-build-'));
  try {
    if (args.skipBuild && !args.schemaTool) {
      throw new Error('--skip-build requires --schema-tool');
    }
    const schemaTool = args.schemaTool || buildSchemaTool(repoRoot, buildRoot);

    const freshDb = join(tempRoot, 'fresh-swift.sqlite');
    runSwiftMigration(schemaTool, freshDb);
    assertSwiftSchemaBeforeNode(freshDb, 'fresh');
    assertNodeCanRead(freshDb, 'fresh');

    const migratedDb = join(tempRoot, 'migrated-swift.sqlite');
    prepareLegacyDatabase(migratedDb);
    runSwiftMigration(schemaTool, migratedDb);
    assertSwiftSchemaBeforeNode(migratedDb, 'migrated');
    assertNodeCanRead(migratedDb, 'migrated');
    assertLegacyRowPreserved(migratedDb);

    console.log('swift schema compatibility ok');
  } finally {
    rmSync(tempRoot, { recursive: true, force: true });
    rmSync(buildRoot, { recursive: true, force: true });
  }
}

const invokedPath = process.argv[1] ? pathToFileURL(process.argv[1]).href : '';
if (import.meta.url === invokedPath) {
  try {
    run(parseArgs(process.argv.slice(2)));
  } catch (error) {
    console.error(error instanceof Error ? error.message : String(error));
    process.exit(1);
  }
}
