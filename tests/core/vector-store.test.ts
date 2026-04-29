import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import BetterSqlite3 from 'better-sqlite3';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { SqliteVecStore } from '../../src/core/vector-store.js';

describe('SqliteVecStore', () => {
  let rawDb: BetterSqlite3.Database;
  let store: SqliteVecStore;
  let tmpDir: string;

  beforeEach(() => {
    tmpDir = mkdtempSync(join(tmpdir(), 'vec-test-'));
    rawDb = new BetterSqlite3(join(tmpDir, 'test.sqlite'));
    rawDb.pragma('foreign_keys = ON');
    // Create sessions table for FK constraint
    rawDb.exec(`CREATE TABLE IF NOT EXISTS sessions (
      id TEXT PRIMARY KEY,
      source TEXT NOT NULL DEFAULT '',
      start_time TEXT NOT NULL DEFAULT '',
      file_path TEXT NOT NULL DEFAULT '',
      cwd TEXT NOT NULL DEFAULT '',
      message_count INTEGER NOT NULL DEFAULT 0,
      user_message_count INTEGER NOT NULL DEFAULT 0,
      size_bytes INTEGER NOT NULL DEFAULT 0
    )`);
    store = new SqliteVecStore(rawDb);
  });

  afterEach(() => {
    rawDb.close();
    rmSync(tmpDir, { recursive: true });
  });

  function addSession(id: string) {
    rawDb.prepare('INSERT OR IGNORE INTO sessions (id) VALUES (?)').run(id);
  }

  it('stores and retrieves vectors by KNN', () => {
    const vec1 = new Float32Array(768).fill(0.1);
    const vec2 = new Float32Array(768).fill(0.9);
    addSession('session-1');
    addSession('session-2');
    store.upsert('session-1', vec1);
    store.upsert('session-2', vec2);

    const query = new Float32Array(768).fill(0.85);
    const results = store.search(query, 2);
    expect(results).toHaveLength(2);
    expect(results[0].sessionId).toBe('session-2'); // closest
  });

  it('deletes a vector', () => {
    const vec = new Float32Array(768).fill(0.5);
    addSession('session-1');
    store.upsert('session-1', vec);
    store.delete('session-1');
    const results = store.search(vec, 10);
    expect(results).toHaveLength(0);
  });

  it('upsert overwrites existing vector', () => {
    const vec1 = new Float32Array(768).fill(0.1);
    const vec2 = new Float32Array(768).fill(0.9);
    addSession('session-1');
    store.upsert('session-1', vec1);
    store.upsert('session-1', vec2);
    const query = new Float32Array(768).fill(0.85);
    const results = store.search(query, 1);
    expect(results[0].sessionId).toBe('session-1');
  });

  it('counts stored embeddings', () => {
    expect(store.count()).toBe(0);
    addSession('s1');
    addSession('s2');
    store.upsert('s1', new Float32Array(768).fill(0.1));
    store.upsert('s2', new Float32Array(768).fill(0.2));
    expect(store.count()).toBe(2);
  });

  // --- Chunk tests ---

  it('stores and searches chunks', () => {
    addSession('s1');
    const chunks = [
      { chunkId: 'c1', sessionId: 's1', chunkIndex: 0, text: 'hello world' },
      { chunkId: 'c2', sessionId: 's1', chunkIndex: 1, text: 'goodbye world' },
    ];
    const embeddings = [
      new Float32Array(768).fill(0.1),
      new Float32Array(768).fill(0.9),
    ];
    store.upsertChunks(chunks, embeddings, 'test-model');

    const query = new Float32Array(768).fill(0.85);
    const results = store.searchChunks(query, 2);
    expect(results).toHaveLength(2);
    expect(results[0].chunkId).toBe('c2'); // closest
    expect(results[0].sessionId).toBe('s1');
    expect(results[0].text).toBe('goodbye world');
  });

  it('upsertChunks replaces existing chunks for same session', () => {
    addSession('s1');
    const chunks1 = [
      { chunkId: 'c1', sessionId: 's1', chunkIndex: 0, text: 'old' },
    ];
    store.upsertChunks(chunks1, [new Float32Array(768).fill(0.1)], 'model');

    const chunks2 = [
      { chunkId: 'c2', sessionId: 's1', chunkIndex: 0, text: 'new' },
    ];
    store.upsertChunks(chunks2, [new Float32Array(768).fill(0.9)], 'model');

    const results = store.searchChunks(new Float32Array(768).fill(0.5), 10);
    expect(results).toHaveLength(1);
    expect(results[0].text).toBe('new');
  });

  it('deleteChunksBySession removes all chunks for a session', () => {
    addSession('s1');
    const chunks = [
      { chunkId: 'c1', sessionId: 's1', chunkIndex: 0, text: 'a' },
      { chunkId: 'c2', sessionId: 's1', chunkIndex: 1, text: 'b' },
    ];
    store.upsertChunks(
      chunks,
      [new Float32Array(768).fill(0.1), new Float32Array(768).fill(0.2)],
      'model',
    );

    store.deleteChunksBySession('s1');
    const results = store.searchChunks(new Float32Array(768).fill(0.1), 10);
    expect(results).toHaveLength(0);
  });

  // --- Insight tests ---

  it('stores and searches insights', () => {
    store.upsertInsight(
      'i1',
      'use dependency injection',
      new Float32Array(768).fill(0.3),
      'model',
      {
        wing: 'myproject',
        room: 'architecture',
        importance: 5,
      },
    );
    store.upsertInsight(
      'i2',
      'prefer composition',
      new Float32Array(768).fill(0.7),
      'model',
      {
        wing: 'myproject',
        room: 'design',
      },
    );

    const query = new Float32Array(768).fill(0.65);
    const results = store.searchInsights(query, 2);
    expect(results).toHaveLength(2);
    expect(results[0].id).toBe('i2'); // closest
    expect(results[0].content).toBe('prefer composition');
    expect(results[0].wing).toBe('myproject');
  });

  it('deleteInsight soft-deletes and excludes from search', () => {
    store.upsertInsight(
      'i1',
      'test insight',
      new Float32Array(768).fill(0.5),
      'model',
    );
    store.deleteInsight('i1');
    const results = store.searchInsights(new Float32Array(768).fill(0.5), 10);
    expect(results).toHaveLength(0);
  });

  it('countInsights counts non-deleted insights', () => {
    expect(store.countInsights()).toBe(0);
    store.upsertInsight('i1', 'a', new Float32Array(768).fill(0.1), 'model');
    store.upsertInsight('i2', 'b', new Float32Array(768).fill(0.2), 'model');
    expect(store.countInsights()).toBe(2);
    store.deleteInsight('i1');
    expect(store.countInsights()).toBe(1);
  });

  // --- Model tracking ---

  it('tracks active model', () => {
    expect(store.activeModel()).toBeNull();
    (store as any).setActiveModel('nomic-embed-text');
    expect(store.activeModel()).toBe('nomic-embed-text');
  });

  it('dropAndRebuild clears all vector data', () => {
    addSession('s1');
    store.upsert('s1', new Float32Array(768).fill(0.1));
    store.upsertInsight('i1', 'test', new Float32Array(768).fill(0.2), 'model');
    store.upsertChunks(
      [{ chunkId: 'c1', sessionId: 's1', chunkIndex: 0, text: 'chunk' }],
      [new Float32Array(768).fill(0.3)],
      'model',
    );

    store.dropAndRebuild();

    expect(store.count()).toBe(0);
    expect(store.countInsights()).toBe(0);
    expect(
      store.searchChunks(new Float32Array(768).fill(0.1), 10),
    ).toHaveLength(0);
  });
});
