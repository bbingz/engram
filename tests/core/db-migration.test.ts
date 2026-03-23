import { describe, it, expect, afterEach } from 'vitest'
import { Database, SCHEMA_VERSION } from '../../src/core/db.js'
import BetterSqlite3 from 'better-sqlite3'
import { mkdtempSync, rmSync } from 'fs'
import { tmpdir } from 'os'
import { join } from 'path'

describe('Database migration', () => {
  const tmpDirs: string[] = []

  function makeTmpDb(): string {
    const dir = mkdtempSync(join(tmpdir(), 'engram-migration-test-'))
    tmpDirs.push(dir)
    return join(dir, 'test.sqlite')
  }

  afterEach(() => {
    for (const dir of tmpDirs) {
      try { rmSync(dir, { recursive: true }) } catch {}
    }
    tmpDirs.length = 0
  })

  // 1. Fresh DB gets all tables
  it('fresh database gets all required tables', () => {
    const dbPath = makeTmpDb()
    const db = new Database(dbPath)

    const tables = db.raw.prepare(
      "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name"
    ).all() as { name: string }[]
    const tableNames = tables.map(t => t.name)

    // Core tables
    expect(tableNames).toContain('sessions')
    expect(tableNames).toContain('metadata')
    expect(tableNames).toContain('sync_state')
    expect(tableNames).toContain('project_aliases')
    expect(tableNames).toContain('session_local_state')
    expect(tableNames).toContain('session_index_jobs')
    expect(tableNames).toContain('usage_snapshots')
    expect(tableNames).toContain('git_repos')
    expect(tableNames).toContain('session_costs')
    expect(tableNames).toContain('session_tools')
    expect(tableNames).toContain('session_files')
    expect(tableNames).toContain('logs')
    expect(tableNames).toContain('traces')

    // FTS virtual table
    expect(tableNames).toContain('sessions_fts')

    // Schema version set
    expect(db.getMetadata('schema_version')).toBe(String(SCHEMA_VERSION))

    db.close()
  })

  // 2. Existing DB with old schema gets new columns added
  it('existing database with minimal schema gets columns added on re-open', () => {
    const dbPath = makeTmpDb()

    // Create a minimal DB with only the sessions table (simulating an old schema)
    const rawDb = new BetterSqlite3(dbPath)
    rawDb.exec(`
      CREATE TABLE sessions (
        id TEXT PRIMARY KEY,
        source TEXT NOT NULL,
        start_time TEXT NOT NULL,
        end_time TEXT,
        cwd TEXT NOT NULL DEFAULT '',
        project TEXT,
        model TEXT,
        message_count INTEGER NOT NULL DEFAULT 0,
        user_message_count INTEGER NOT NULL DEFAULT 0,
        summary TEXT,
        file_path TEXT NOT NULL,
        size_bytes INTEGER NOT NULL DEFAULT 0,
        indexed_at TEXT NOT NULL DEFAULT (datetime('now'))
      );
    `)
    rawDb.close()

    // Re-open with Database class — should run migration
    const db = new Database(dbPath)

    const cols = db.raw.prepare("PRAGMA table_info(sessions)").all() as { name: string }[]
    const colNames = cols.map(c => c.name)

    // Columns added by migration
    expect(colNames).toContain('agent_role')
    expect(colNames).toContain('tier')
    expect(colNames).toContain('quality_score')
    expect(colNames).toContain('origin')
    expect(colNames).toContain('sync_version')
    expect(colNames).toContain('generated_title')
    expect(colNames).toContain('assistant_message_count')
    expect(colNames).toContain('tool_message_count')
    expect(colNames).toContain('system_message_count')

    db.close()
  })

  // 3. Migration is idempotent across multiple opens
  it('migration is idempotent — opening DB multiple times does not error', () => {
    const dbPath = makeTmpDb()

    // Open and close three times — should not throw
    const db1 = new Database(dbPath)
    db1.close()

    const db2 = new Database(dbPath)
    db2.close()

    const db3 = new Database(dbPath)

    // Verify schema is intact after multiple opens
    const tables = db3.raw.prepare(
      "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name"
    ).all() as { name: string }[]
    const tableNames = tables.map(t => t.name)
    expect(tableNames).toContain('sessions')
    expect(tableNames).toContain('metadata')
    expect(tableNames).toContain('logs')

    // Schema version still correct
    expect(db3.getMetadata('schema_version')).toBe(String(SCHEMA_VERSION))

    db3.close()
  })
})
