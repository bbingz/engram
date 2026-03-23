#!/usr/bin/env tsx
import { SCHEMA_VERSION } from '../src/core/db.js'
import BetterSqlite3 from 'better-sqlite3'
import { resolve, dirname } from 'path'
import { fileURLToPath } from 'url'

const __dirname = dirname(fileURLToPath(import.meta.url))
const fixturePath = resolve(__dirname, '../test-fixtures/test-index.sqlite')

const db = new BetterSqlite3(fixturePath, { readonly: true })
const row = db.prepare("SELECT value FROM metadata WHERE key = 'schema_version'").get() as { value: string } | undefined
db.close()

if (!row) {
  console.error('ERROR: No schema_version found in fixture metadata table')
  process.exit(1)
}

const fixtureVersion = Number(row.value)
if (fixtureVersion !== SCHEMA_VERSION) {
  console.error(`ERROR: Fixture schema_version (${fixtureVersion}) != SCHEMA_VERSION (${SCHEMA_VERSION})`)
  console.error('Run: npm run generate:fixtures')
  process.exit(1)
}

console.log(`OK: schema_version = ${SCHEMA_VERSION}`)
