import { describe, it, expect, beforeEach, afterEach } from 'vitest'
import { SqliteVecStore } from '../../src/core/vector-store.js'
import BetterSqlite3 from 'better-sqlite3'
import { mkdtempSync, rmSync } from 'fs'
import { tmpdir } from 'os'
import { join } from 'path'

describe('SqliteVecStore', () => {
  let rawDb: BetterSqlite3.Database
  let store: SqliteVecStore
  let tmpDir: string

  beforeEach(() => {
    tmpDir = mkdtempSync(join(tmpdir(), 'vec-test-'))
    rawDb = new BetterSqlite3(join(tmpDir, 'test.sqlite'))
    store = new SqliteVecStore(rawDb)
  })

  afterEach(() => {
    rawDb.close()
    rmSync(tmpDir, { recursive: true })
  })

  it('stores and retrieves vectors by KNN', () => {
    const vec1 = new Float32Array(768).fill(0.1)
    const vec2 = new Float32Array(768).fill(0.9)
    store.upsert('session-1', vec1)
    store.upsert('session-2', vec2)

    const query = new Float32Array(768).fill(0.85)
    const results = store.search(query, 2)
    expect(results).toHaveLength(2)
    expect(results[0].sessionId).toBe('session-2') // closest
  })

  it('deletes a vector', () => {
    const vec = new Float32Array(768).fill(0.5)
    store.upsert('session-1', vec)
    store.delete('session-1')
    const results = store.search(vec, 10)
    expect(results).toHaveLength(0)
  })

  it('upsert overwrites existing vector', () => {
    const vec1 = new Float32Array(768).fill(0.1)
    const vec2 = new Float32Array(768).fill(0.9)
    store.upsert('session-1', vec1)
    store.upsert('session-1', vec2)
    const query = new Float32Array(768).fill(0.85)
    const results = store.search(query, 1)
    expect(results[0].sessionId).toBe('session-1')
  })

  it('counts stored embeddings', () => {
    expect(store.count()).toBe(0)
    store.upsert('s1', new Float32Array(768).fill(0.1))
    store.upsert('s2', new Float32Array(768).fill(0.2))
    expect(store.count()).toBe(2)
  })
})
