import { describe, it, expect, beforeAll, afterAll } from 'vitest'
import { OpenCodeAdapter } from '../../src/adapters/opencode.js'
import Database from 'better-sqlite3'
import { join, dirname } from 'path'
import { fileURLToPath } from 'url'
import { mkdirSync, rmSync } from 'fs'

const __dirname = dirname(fileURLToPath(import.meta.url))
const FIXTURE_DIR = join(__dirname, '../fixtures/opencode')
const FIXTURE_DB = join(FIXTURE_DIR, 'sample.db')

beforeAll(() => {
  mkdirSync(FIXTURE_DIR, { recursive: true })
  const db = new Database(FIXTURE_DB)
  db.exec(`
    CREATE TABLE session (
      id TEXT PRIMARY KEY, project_id TEXT NOT NULL, parent_id TEXT,
      slug TEXT NOT NULL, directory TEXT NOT NULL, title TEXT NOT NULL,
      version TEXT NOT NULL, share_url TEXT, summary_additions INTEGER,
      summary_deletions INTEGER, summary_files INTEGER, summary_diffs TEXT,
      revert TEXT, permission TEXT,
      time_created INTEGER NOT NULL, time_updated INTEGER NOT NULL,
      time_compacting INTEGER, time_archived INTEGER
    );
    CREATE TABLE message (
      id TEXT PRIMARY KEY, session_id TEXT NOT NULL,
      time_created INTEGER NOT NULL, time_updated INTEGER NOT NULL,
      data TEXT NOT NULL
    );
    CREATE TABLE part (
      id TEXT PRIMARY KEY, message_id TEXT NOT NULL,
      time_created INTEGER NOT NULL, time_updated INTEGER NOT NULL,
      data TEXT NOT NULL
    );
    INSERT INTO session VALUES (
      'ses_test001', 'proj_001', NULL, 'test-session', '/Users/test/my-project',
      '实现用户登录功能', '0.0.1', NULL, 3, 10, 2, NULL, NULL, NULL,
      1770000000000, 1770000060000, NULL, NULL
    );
    INSERT INTO message VALUES (
      'msg_001', 'ses_test001', 1770000001000, 1770000001000,
      '{"role":"user","time":{"created":1770000001000}}'
    );
    INSERT INTO part VALUES (
      'part_001', 'msg_001', 1770000001000, 1770000001000,
      '{"type":"text","text":"帮我实现登录功能"}'
    );
    INSERT INTO message VALUES (
      'msg_002', 'ses_test001', 1770000010000, 1770000010000,
      '{"role":"assistant","time":{"created":1770000010000,"completed":1770000015000}}'
    );
    INSERT INTO part VALUES (
      'part_002', 'msg_002', 1770000010000, 1770000010000,
      '{"type":"text","text":"好的，我来实现登录功能。"}'
    );
  `)
  db.close()
})

afterAll(() => {
  try { rmSync(FIXTURE_DB) } catch { /* ignore */ }
})

describe('OpenCodeAdapter', () => {
  const adapter = new OpenCodeAdapter(FIXTURE_DB)

  it('name is opencode', () => {
    expect(adapter.name).toBe('opencode')
  })

  it('listSessionFiles yields virtual paths', async () => {
    const files: string[] = []
    for await (const f of adapter.listSessionFiles()) files.push(f)
    expect(files).toHaveLength(1)
    expect(files[0]).toContain('ses_test001')
  })

  it('parseSessionInfo extracts metadata from virtual path', async () => {
    const files: string[] = []
    for await (const f of adapter.listSessionFiles()) files.push(f)
    const info = await adapter.parseSessionInfo(files[0])
    expect(info).not.toBeNull()
    expect(info!.id).toBe('ses_test001')
    expect(info!.source).toBe('opencode')
    expect(info!.cwd).toBe('/Users/test/my-project')
    expect(info!.summary).toBe('实现用户登录功能')
    expect(info!.messageCount).toBe(2)
  })

  it('streamMessages yields messages', async () => {
    const files: string[] = []
    for await (const f of adapter.listSessionFiles()) files.push(f)
    const messages = []
    for await (const msg of adapter.streamMessages(files[0])) messages.push(msg)
    expect(messages.length).toBeGreaterThanOrEqual(1)
  })
})
