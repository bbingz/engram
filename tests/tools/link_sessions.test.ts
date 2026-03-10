// tests/tools/link_sessions.test.ts
import { describe, it, expect, beforeEach, afterEach } from 'vitest'
import { handleLinkSessions } from '../../src/tools/link_sessions.js'
import { Database } from '../../src/core/db.js'
import { mkdtempSync, rmSync, writeFileSync, readlinkSync, lstatSync } from 'fs'
import { tmpdir } from 'os'
import { join } from 'path'

describe('link_sessions', () => {
  let db: Database
  let tmpDir: string
  let sourceDir: string
  let targetDir: string

  beforeEach(() => {
    tmpDir = mkdtempSync(join(tmpdir(), 'link-sessions-test-'))
    sourceDir = join(tmpDir, 'sources')
    targetDir = join(tmpDir, 'myapp')

    // Create source files that sessions point to
    const mkdirSync = require('fs').mkdirSync
    mkdirSync(join(sourceDir, 'claude-code'), { recursive: true })
    mkdirSync(join(sourceDir, 'codex'), { recursive: true })
    mkdirSync(targetDir, { recursive: true })

    writeFileSync(join(sourceDir, 'claude-code', 'session1.jsonl'), '{}')
    writeFileSync(join(sourceDir, 'claude-code', 'session2.jsonl'), '{}')
    writeFileSync(join(sourceDir, 'codex', 'session3.jsonl'), '{}')

    db = new Database(join(tmpDir, 'test.sqlite'))
    db.upsertSession({
      id: 's1', source: 'claude-code', startTime: '2026-01-20T10:00:00Z',
      cwd: '/Users/test/myapp', project: 'myapp', messageCount: 10,
      userMessageCount: 5, assistantMessageCount: 3, toolMessageCount: 0, systemMessageCount: 0,
      filePath: join(sourceDir, 'claude-code', 'session1.jsonl'), sizeBytes: 100,
    })
    db.upsertSession({
      id: 's2', source: 'claude-code', startTime: '2026-01-21T10:00:00Z',
      cwd: '/Users/test/myapp', project: 'myapp', messageCount: 8,
      userMessageCount: 4, assistantMessageCount: 3, toolMessageCount: 0, systemMessageCount: 0,
      filePath: join(sourceDir, 'claude-code', 'session2.jsonl'), sizeBytes: 80,
    })
    db.upsertSession({
      id: 's3', source: 'codex', startTime: '2026-01-22T10:00:00Z',
      cwd: '/Users/test/myapp', project: 'myapp', messageCount: 5,
      userMessageCount: 2, assistantMessageCount: 2, toolMessageCount: 0, systemMessageCount: 0,
      filePath: join(sourceDir, 'codex', 'session3.jsonl'), sizeBytes: 50,
    })
    db.upsertSession({
      id: 's4', source: 'claude-code', startTime: '2026-01-23T10:00:00Z',
      cwd: '/Users/test/other', project: 'other', messageCount: 12,
      userMessageCount: 6, assistantMessageCount: 4, toolMessageCount: 0, systemMessageCount: 0,
      filePath: join(sourceDir, 'claude-code', 'other.jsonl'), sizeBytes: 60,
    })
  })

  afterEach(() => {
    db.close()
    rmSync(tmpDir, { recursive: true })
  })

  it('creates symlinks grouped by source', async () => {
    const result = await handleLinkSessions(db, { targetDir })
    expect(result.created).toBe(3)
    expect(result.skipped).toBe(0)
    expect(result.errors).toEqual([])

    // Verify symlinks exist and point to correct targets
    const link1 = join(targetDir, 'conversation_log', 'claude-code', 'session1.jsonl')
    const link2 = join(targetDir, 'conversation_log', 'claude-code', 'session2.jsonl')
    const link3 = join(targetDir, 'conversation_log', 'codex', 'session3.jsonl')

    expect(lstatSync(link1).isSymbolicLink()).toBe(true)
    expect(readlinkSync(link1)).toBe(join(sourceDir, 'claude-code', 'session1.jsonl'))
    expect(lstatSync(link2).isSymbolicLink()).toBe(true)
    expect(lstatSync(link3).isSymbolicLink()).toBe(true)
    expect(readlinkSync(link3)).toBe(join(sourceDir, 'codex', 'session3.jsonl'))
  })

  it('skips existing symlinks pointing to same target', async () => {
    // First run
    await handleLinkSessions(db, { targetDir })

    // Second run — should skip all
    const result = await handleLinkSessions(db, { targetDir })
    expect(result.created).toBe(0)
    expect(result.skipped).toBe(3)
  })

  it('does not include sessions from other projects', async () => {
    const result = await handleLinkSessions(db, { targetDir })
    expect(result.created).toBe(3) // only myapp sessions, not 'other'
  })

  it('resolves project aliases', async () => {
    db.addProjectAlias('myapp', 'myapp-renamed')
    db.upsertSession({
      id: 's5', source: 'codex', startTime: '2026-01-24T10:00:00Z',
      cwd: '/Users/test/myapp-renamed', project: 'myapp-renamed', messageCount: 3,
      userMessageCount: 1, assistantMessageCount: 1, toolMessageCount: 0, systemMessageCount: 0,
      filePath: join(sourceDir, 'codex', 'session3.jsonl'), sizeBytes: 30,
    })

    const result = await handleLinkSessions(db, { targetDir })
    // Should include both myapp and myapp-renamed sessions
    expect(result.created).toBeGreaterThanOrEqual(3)
    expect(result.projectNames).toContain('myapp')
    expect(result.projectNames).toContain('myapp-renamed')
  })

  it('returns empty result for unknown project', async () => {
    const unknownDir = join(tmpDir, 'unknown-project')
    require('fs').mkdirSync(unknownDir, { recursive: true })
    const result = await handleLinkSessions(db, { targetDir: unknownDir })
    expect(result.created).toBe(0)
    expect(result.skipped).toBe(0)
  })
})
