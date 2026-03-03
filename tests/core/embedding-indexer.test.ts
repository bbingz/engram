import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import { EmbeddingIndexer } from '../../src/core/embedding-indexer.js'
import type { VectorStore } from '../../src/core/vector-store.js'
import type { EmbeddingClient } from '../../src/core/embeddings.js'
import { Database } from '../../src/core/db.js'
import { mkdtempSync, rmSync } from 'fs'
import { tmpdir } from 'os'
import { join } from 'path'

describe('EmbeddingIndexer', () => {
  let db: Database
  let tmpDir: string
  let mockStore: VectorStore
  let mockClient: EmbeddingClient
  let indexer: EmbeddingIndexer

  beforeEach(() => {
    tmpDir = mkdtempSync(join(tmpdir(), 'embed-idx-test-'))
    db = new Database(join(tmpDir, 'test.sqlite'))

    mockStore = {
      upsert: vi.fn(),
      search: vi.fn().mockReturnValue([]),
      delete: vi.fn(),
      count: vi.fn().mockReturnValue(0),
    }

    mockClient = {
      embed: vi.fn().mockResolvedValue(new Float32Array(768).fill(0.1)),
      dimension: 768,
      model: 'mock',
    }

    indexer = new EmbeddingIndexer(db, mockStore, mockClient)
  })

  afterEach(() => {
    db.close()
    rmSync(tmpDir, { recursive: true })
  })

  it('indexes a session that has FTS content', async () => {
    db.upsertSession({
      id: 's1', source: 'codex', startTime: '2026-01-01T10:00:00Z',
      cwd: '/p', messageCount: 5, userMessageCount: 2,
      filePath: '/f1', sizeBytes: 100,
    })
    db.indexSessionContent('s1', [
      { role: 'user', content: 'Help me fix the login bug' },
    ])

    const count = await indexer.indexAll()
    expect(count).toBe(1)
    expect(mockClient.embed).toHaveBeenCalledOnce()
    expect(mockStore.upsert).toHaveBeenCalledOnce()
  })

  it('skips sessions without FTS content', async () => {
    db.upsertSession({
      id: 's1', source: 'codex', startTime: '2026-01-01T10:00:00Z',
      cwd: '/p', messageCount: 0, userMessageCount: 0,
      filePath: '/f1', sizeBytes: 100,
    })
    // No indexSessionContent call - no FTS data

    const count = await indexer.indexAll()
    expect(count).toBe(0)
    expect(mockClient.embed).not.toHaveBeenCalled()
  })

  it('skips already-indexed sessions on second call', async () => {
    db.upsertSession({
      id: 's1', source: 'codex', startTime: '2026-01-01T10:00:00Z',
      cwd: '/p', messageCount: 5, userMessageCount: 2,
      filePath: '/f1', sizeBytes: 100,
    })
    db.indexSessionContent('s1', [
      { role: 'user', content: 'Hello world test' },
    ])

    await indexer.indexAll()
    vi.mocked(mockClient.embed).mockClear()
    vi.mocked(mockStore.upsert).mockClear()

    const count = await indexer.indexAll()
    expect(count).toBe(0)
    expect(mockClient.embed).not.toHaveBeenCalled()
  })

  it('indexOne indexes a single session', async () => {
    db.upsertSession({
      id: 's1', source: 'codex', startTime: '2026-01-01T10:00:00Z',
      cwd: '/p', messageCount: 5, userMessageCount: 2,
      filePath: '/f1', sizeBytes: 100,
    })
    db.indexSessionContent('s1', [
      { role: 'user', content: 'Fix the auth bug' },
    ])

    const result = await indexer.indexOne('s1')
    expect(result).toBe(true)
    expect(mockStore.upsert).toHaveBeenCalledOnce()
  })
})
