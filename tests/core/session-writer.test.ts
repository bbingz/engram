import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { mkdtempSync, rmSync } from 'fs'
import { tmpdir } from 'os'
import { join } from 'path'
import { Database } from '../../src/core/db.js'
import { SessionSnapshotWriter } from '../../src/core/session-writer.js'

describe('SessionSnapshotWriter', () => {
  let db: Database
  let tmpDir: string

  beforeEach(() => {
    tmpDir = mkdtempSync(join(tmpdir(), 'session-writer-test-'))
    db = new Database(join(tmpDir, 'test.sqlite'))
  })

  afterEach(() => {
    db.close()
    rmSync(tmpDir, { recursive: true })
  })

  it('persists merged snapshot and durable jobs in one write path', () => {
    const writer = new SessionSnapshotWriter(db)

    writer.writeAuthoritativeSnapshot({
      id: 'sess-1',
      source: 'codex',
      authoritativeNode: 'node-a',
      syncVersion: 1,
      snapshotHash: 'hash-1',
      indexedAt: '2026-03-18T12:00:00Z',
      sourceLocator: '/tmp/rollout.jsonl',
      startTime: '2026-03-18T11:00:00Z',
      cwd: '/repo',
      messageCount: 2,
      userMessageCount: 1,
      assistantMessageCount: 1,
      toolMessageCount: 0,
      systemMessageCount: 0,
      summary: 'hello',
    })

    expect(db.getSession('sess-1')?.summary).toBe('hello')
    expect(db.listIndexJobs('sess-1').map(j => j.jobKind).sort()).toEqual(['embedding', 'fts'])
  })

  it('returns noop and does not create duplicate jobs for identical payloads', () => {
    const writer = new SessionSnapshotWriter(db)
    const snapshot = {
      id: 'sess-1',
      source: 'codex' as const,
      authoritativeNode: 'node-a',
      syncVersion: 1,
      snapshotHash: 'hash-1',
      indexedAt: '2026-03-18T12:00:00Z',
      sourceLocator: '/tmp/rollout.jsonl',
      startTime: '2026-03-18T11:00:00Z',
      cwd: '/repo',
      messageCount: 2,
      userMessageCount: 1,
      assistantMessageCount: 1,
      toolMessageCount: 0,
      systemMessageCount: 0,
      summary: 'hello',
    }

    writer.writeAuthoritativeSnapshot(snapshot)
    const second = writer.writeAuthoritativeSnapshot(snapshot)

    expect(second.action).toBe('noop')
    expect(db.listIndexJobs('sess-1')).toHaveLength(2)
  })

  describe('tier-gated job dispatch', () => {
    it('skip tier → 0 index jobs', () => {
      const writer = new SessionSnapshotWriter(db)

      writer.writeAuthoritativeSnapshot({
        id: 'sess-skip',
        source: 'codex',
        authoritativeNode: 'node-a',
        syncVersion: 1,
        snapshotHash: 'hash-skip',
        indexedAt: '2026-03-18T12:00:00Z',
        sourceLocator: '/tmp/skip.jsonl',
        startTime: '2026-03-18T11:00:00Z',
        cwd: '/repo',
        messageCount: 2,
        userMessageCount: 1,
        assistantMessageCount: 1,
        toolMessageCount: 0,
        systemMessageCount: 0,
        summary: 'unique summary for skip tier test',
        tier: 'skip',
      })

      expect(db.listIndexJobs('sess-skip')).toHaveLength(0)
    })

    it('lite tier → FTS job only', () => {
      const writer = new SessionSnapshotWriter(db)

      writer.writeAuthoritativeSnapshot({
        id: 'sess-lite',
        source: 'codex',
        authoritativeNode: 'node-a',
        syncVersion: 1,
        snapshotHash: 'hash-lite',
        indexedAt: '2026-03-18T12:00:00Z',
        sourceLocator: '/tmp/lite.jsonl',
        startTime: '2026-03-18T11:00:00Z',
        cwd: '/repo',
        messageCount: 2,
        userMessageCount: 1,
        assistantMessageCount: 1,
        toolMessageCount: 0,
        systemMessageCount: 0,
        summary: 'unique summary for lite tier test',
        tier: 'lite',
      })

      const jobs = db.listIndexJobs('sess-lite').map(j => j.jobKind)
      expect(jobs).toEqual(['fts'])
    })

    it('normal tier → FTS + embedding jobs', () => {
      const writer = new SessionSnapshotWriter(db)

      writer.writeAuthoritativeSnapshot({
        id: 'sess-normal',
        source: 'codex',
        authoritativeNode: 'node-a',
        syncVersion: 1,
        snapshotHash: 'hash-normal',
        indexedAt: '2026-03-18T12:00:00Z',
        sourceLocator: '/tmp/normal.jsonl',
        startTime: '2026-03-18T11:00:00Z',
        cwd: '/repo',
        messageCount: 2,
        userMessageCount: 1,
        assistantMessageCount: 1,
        toolMessageCount: 0,
        systemMessageCount: 0,
        summary: 'unique summary for normal tier test',
        tier: 'normal',
      })

      const jobs = db.listIndexJobs('sess-normal').map(j => j.jobKind).sort()
      expect(jobs).toEqual(['embedding', 'fts'])
    })

    it('premium tier → FTS + embedding jobs', () => {
      const writer = new SessionSnapshotWriter(db)

      writer.writeAuthoritativeSnapshot({
        id: 'sess-premium',
        source: 'codex',
        authoritativeNode: 'node-a',
        syncVersion: 1,
        snapshotHash: 'hash-premium',
        indexedAt: '2026-03-18T12:00:00Z',
        sourceLocator: '/tmp/premium.jsonl',
        startTime: '2026-03-18T11:00:00Z',
        cwd: '/repo',
        messageCount: 2,
        userMessageCount: 1,
        assistantMessageCount: 1,
        toolMessageCount: 0,
        systemMessageCount: 0,
        summary: 'unique summary for premium tier test',
        tier: 'premium',
      })

      const jobs = db.listIndexJobs('sess-premium').map(j => j.jobKind).sort()
      expect(jobs).toEqual(['embedding', 'fts'])
    })
  })
})
