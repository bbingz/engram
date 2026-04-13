import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import BetterSqlite3 from 'better-sqlite3';
import { describe, expect, it } from 'vitest';
import type { EmbeddingClient } from '../../src/core/embeddings.js';
import { SqliteVecStore } from '../../src/core/vector-store.js';
import { handleGetMemory } from '../../src/tools/get_memory.js';

function makeStore() {
  const tmpDir = mkdtempSync(join(tmpdir(), 'memory-test-'));
  const db = new BetterSqlite3(join(tmpDir, 'test.sqlite'));
  db.exec('CREATE TABLE IF NOT EXISTS sessions (id TEXT PRIMARY KEY)');
  const store = new SqliteVecStore(db);
  return { store, db, tmpDir };
}

function makeMockEmbedder(): EmbeddingClient {
  return {
    dimension: 768,
    model: 'mock',
    embed: async () => {
      const arr = new Float32Array(768).fill(0.036);
      const norm = Math.sqrt(arr.reduce((s, v) => s + v * v, 0));
      for (let i = 0; i < 768; i++) arr[i] /= norm;
      return arr;
    },
  };
}

describe('handleGetMemory', () => {
  it('returns memories from local insights', async () => {
    const { store, db, tmpDir } = makeStore();
    const embedder = makeMockEmbedder();

    const vec = new Float32Array(768).fill(0.036);
    const norm = Math.sqrt(vec.reduce((s, v) => s + v * v, 0));
    for (let i = 0; i < 768; i++) vec[i] /= norm;
    store.upsertInsight('i1', 'User prefers TypeScript', vec, 'mock', {
      wing: 'myproject',
    });

    const result = await handleGetMemory(
      { query: 'coding style' },
      { vecStore: store, embedder },
    );
    expect(result.memories).toHaveLength(1);
    expect(result.memories[0].content).toBe('User prefers TypeScript');

    db.close();
    rmSync(tmpDir, { recursive: true });
  });

  it('returns helpful message when no embedder available', async () => {
    const result = await handleGetMemory({ query: 'coding style' }, {});
    expect(result.memories).toHaveLength(0);
    expect(result.warning).toContain('No embedding provider');
  });

  it('returns helpful message when no memories exist', async () => {
    const { store, db, tmpDir } = makeStore();
    const embedder = makeMockEmbedder();

    const result = await handleGetMemory(
      { query: 'something' },
      { vecStore: store, embedder },
    );
    expect(result.memories).toHaveLength(0);
    expect(result.message).toContain('save_insight');

    db.close();
    rmSync(tmpDir, { recursive: true });
  });
});
