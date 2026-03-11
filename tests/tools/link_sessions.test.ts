// tests/tools/link_sessions.test.ts
import { describe, it, expect, beforeEach, afterEach } from 'vitest'
import { handleLinkSessions } from '../../src/tools/link_sessions.js'
import { Database } from '../../src/core/db.js'
import { mkdtempSync, mkdirSync, rmSync, writeFileSync, readlinkSync, lstatSync } from 'fs'
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
    await handleLinkSessions(db, { targetDir })

    const result = await handleLinkSessions(db, { targetDir })
    expect(result.created).toBe(0)
    expect(result.skipped).toBe(3)
  })

  it('does not include sessions from other projects', async () => {
    const result = await handleLinkSessions(db, { targetDir })
    expect(result.created).toBe(3)
  })

  it('resolves project aliases', async () => {
    // Use a unique filename for the aliased session to avoid collision
    writeFileSync(join(sourceDir, 'codex', 'session5.jsonl'), '{}')
    db.addProjectAlias('myapp', 'myapp-renamed')
    db.upsertSession({
      id: 's5', source: 'codex', startTime: '2026-01-24T10:00:00Z',
      cwd: '/Users/test/myapp-renamed', project: 'myapp-renamed', messageCount: 3,
      userMessageCount: 1, assistantMessageCount: 1, toolMessageCount: 0, systemMessageCount: 0,
      filePath: join(sourceDir, 'codex', 'session5.jsonl'), sizeBytes: 30,
    })

    const result = await handleLinkSessions(db, { targetDir })
    expect(result.created).toBe(4)
    expect(result.errors).toEqual([])
    expect(result.projectNames).toContain('myapp')
    expect(result.projectNames).toContain('myapp-renamed')
  })

  it('returns empty result for unknown project', async () => {
    const unknownDir = join(tmpDir, 'unknown-project')
    mkdirSync(unknownDir, { recursive: true })
    const result = await handleLinkSessions(db, { targetDir: unknownDir })
    expect(result.created).toBe(0)
    expect(result.skipped).toBe(0)
  })

  it('rejects relative path', async () => {
    const result = await handleLinkSessions(db, { targetDir: 'myapp' })
    expect(result.created).toBe(0)
    expect(result.errors).toEqual(['targetDir must be an absolute path'])
  })

  it('replaces symlink when same filename points to different target', async () => {
    // Two sessions with same source + filename but different file paths (via aliases)
    const altDir = join(sourceDir, 'codex-alt')
    mkdirSync(altDir, { recursive: true })
    writeFileSync(join(altDir, 'session3.jsonl'), '{"alt": true}')

    db.addProjectAlias('myapp', 'myapp-v2')
    db.upsertSession({
      id: 's6', source: 'codex', startTime: '2026-01-25T10:00:00Z',
      cwd: '/Users/test/myapp-v2', project: 'myapp-v2', messageCount: 4,
      userMessageCount: 2, assistantMessageCount: 1, toolMessageCount: 0, systemMessageCount: 0,
      filePath: join(altDir, 'session3.jsonl'), sizeBytes: 40,
    })

    const result = await handleLinkSessions(db, { targetDir })
    // One of the two session3.jsonl will be created, the other replaces it — no errors
    expect(result.errors).toEqual([])
    // The link should point to one of the two targets
    const linkPath = join(targetDir, 'conversation_log', 'codex', 'session3.jsonl')
    expect(lstatSync(linkPath).isSymbolicLink()).toBe(true)
  })
})
