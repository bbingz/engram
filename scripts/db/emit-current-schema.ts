#!/usr/bin/env tsx
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import { Database, SCHEMA_VERSION } from '../../src/core/db.js';

interface ColumnInfo {
  cid: number;
  name: string;
  type: string;
  notnull: number;
  dflt_value: string | null;
  pk: number;
}

interface SchemaColumn {
  type: string;
  notNull: boolean;
  defaultValue: string | null;
  primaryKey: boolean;
}

interface SqliteMasterRow {
  type: 'table' | 'index' | 'trigger' | 'view';
  name: string;
  tbl_name: string;
  sql: string | null;
}

function parseArgs(argv: string[]): { out: string } {
  let out = '';
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === '--out') {
      const value = argv[i + 1];
      if (!value) throw new Error('--out requires a value');
      out = resolve(value);
      i += 1;
      continue;
    }
    throw new Error(`unknown argument: ${arg}`);
  }
  if (!out) throw new Error('--out is required');
  return { out };
}

function normalizeSql(sql: string | null): string | null {
  if (!sql) return null;
  return sql.replace(/\s+/g, ' ').trim();
}

function tableColumns(db: ReturnType<Database['getRawDb']>, name: string) {
  const columns = db
    .prepare(`PRAGMA table_info(${JSON.stringify(name)})`)
    .all() as ColumnInfo[];
  const entries = columns
    .sort((a, b) => a.cid - b.cid)
    .map(
      (column) =>
        [
          column.name,
          {
            type: column.type,
            notNull: column.notnull === 1,
            defaultValue: column.dflt_value,
            primaryKey: column.pk > 0,
          } satisfies SchemaColumn,
        ] as const,
    );
  return Object.fromEntries(entries);
}

function emitSchema(out: string): void {
  const tempDir = mkdtempSync(resolve(tmpdir(), 'engram-schema-'));
  const dbPath = resolve(tempDir, 'schema.sqlite');
  const db = new Database(dbPath);
  try {
    const raw = db.getRawDb();
    raw.exec(`
      CREATE TABLE IF NOT EXISTS memory_insights (
        id TEXT PRIMARY KEY,
        content TEXT NOT NULL,
        wing TEXT,
        room TEXT,
        source_session_id TEXT,
        importance INTEGER DEFAULT 5,
        model TEXT NOT NULL DEFAULT 'unknown',
        created_at TEXT DEFAULT (datetime('now')),
        deleted_at TEXT
      );
    `);
    const metadata = Object.fromEntries(
      (
        raw
          .prepare('SELECT key, value FROM metadata ORDER BY key')
          .all() as { key: string; value: string }[]
      ).map((row) => [row.key, row.value]),
    );
    const masterRows = raw
      .prepare(
        `
        SELECT type, name, tbl_name, sql
        FROM sqlite_master
        WHERE name NOT LIKE 'sqlite_%'
        ORDER BY type, name
      `,
      )
      .all() as SqliteMasterRow[];

    const tables = Object.fromEntries(
      masterRows
        .filter((row) => row.type === 'table')
        .map((row) => [
          row.name,
          {
            virtual: row.sql?.includes('CREATE VIRTUAL TABLE') ?? false,
            sql: normalizeSql(row.sql),
            columns: tableColumns(raw, row.name),
          },
        ]),
    );
    const indexes = Object.fromEntries(
      masterRows
        .filter((row) => row.type === 'index')
        .map((row) => [
          row.name,
          { table: row.tbl_name, sql: normalizeSql(row.sql) },
        ]),
    );
    const triggers = Object.fromEntries(
      masterRows
        .filter((row) => row.type === 'trigger')
        .map((row) => [
          row.name,
          { table: row.tbl_name, sql: normalizeSql(row.sql) },
        ]),
    );

    const schema = {
      schemaVersion: SCHEMA_VERSION,
      ftsVersion: metadata.fts_version,
      metadataKeys: Object.keys(metadata).sort(),
      tables,
      indexes,
      triggers,
    };

    mkdirSync(dirname(out), { recursive: true });
    writeFileSync(out, `${JSON.stringify(schema, null, 2)}\n`);
  } finally {
    db.close();
    rmSync(tempDir, { recursive: true, force: true });
  }
}

const invokedPath = process.argv[1] ? pathToFileURL(process.argv[1]).href : '';
if (import.meta.url === invokedPath) {
  try {
    emitSchema(parseArgs(process.argv.slice(2)).out);
  } catch (error) {
    console.error(error instanceof Error ? error.message : String(error));
    process.exit(1);
  }
}
