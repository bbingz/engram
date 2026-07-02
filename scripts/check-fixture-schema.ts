#!/usr/bin/env tsx
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import BetterSqlite3 from 'better-sqlite3';
import { SCHEMA_VERSION } from '../src/core/db.js';

const __dirname = dirname(fileURLToPath(import.meta.url));
const fixturePath = resolve(__dirname, '../test-fixtures/test-index.sqlite');

const db = new BetterSqlite3(fixturePath, { readonly: true });
const row = db
  .prepare("SELECT value FROM metadata WHERE key = 'schema_version'")
  .get() as { value: string } | undefined;

if (!row) {
  db.close();
  console.error('ERROR: No schema_version found in fixture metadata table');
  process.exit(1);
}

const fixtureVersion = Number(row.value);
if (fixtureVersion !== SCHEMA_VERSION) {
  db.close();
  console.error(
    `ERROR: Fixture schema_version (${fixtureVersion}) != SCHEMA_VERSION (${SCHEMA_VERSION})`,
  );
  console.error('Run: npm run generate:fixtures');
  process.exit(1);
}

const requiredSessionColumns = [
  'instruction_count',
  'human_turn_count',
  'instruction_summary',
  'originator',
  'last_accessed_at',
  'access_count',
  'offload_state',
];
const sessionColumns = new Set(
  (
    db.prepare('PRAGMA table_info(sessions)').all() as {
      name: string;
    }[]
  ).map((column) => column.name),
);
db.close();

const missingSessionColumns = requiredSessionColumns.filter(
  (column) => !sessionColumns.has(column),
);
if (missingSessionColumns.length > 0) {
  console.error(
    `ERROR: Fixture sessions table missing columns: ${missingSessionColumns.join(', ')}`,
  );
  console.error('Run: npm run generate:fixtures');
  process.exit(1);
}

console.log(`OK: schema_version = ${SCHEMA_VERSION}`);
