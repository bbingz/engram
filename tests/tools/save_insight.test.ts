import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import BetterSqlite3 from 'better-sqlite3';
import { describe, expect, it } from 'vitest';
import { Database } from '../../src/core/db.js';
import type { EmbeddingClient } from '../../src/core/embeddings.js';
import { SqliteVecStore } from '../../src/core/vector-store.js';
import { handleSaveInsight } from '../../src/tools/save_insight.js';

function makeStore() {
  const tmpDir = mkdtempSync(join(tmpdir(), 'insight-test-'));
  const db = new BetterSqlite3(join(tmpDir, 'test.sqlite'));
  db.exec('CREATE TABLE IF NOT EXISTS sessions (id TEXT PRIMARY KEY)');
  const store = new SqliteVecStore(db);
  return { store, db, tmpDir };
}

function makeMockEmbedder(dim = 768): EmbeddingClient {
  let callCount = 0;
  return {
    dimension: dim,
    model: 'mock-model',
    embed: async (text: string) => {
      // Generate deterministic but varied vectors based on text hash
      const arr = new Float32Array(dim);
      for (let i = 0; i < dim; i++) {
        arr[i] = Math.sin(
          text.charCodeAt(i % text.length) + i + callCount * 0.001,
        );
      }
      callCount++;
      // L2 normalize
      const norm = Math.sqrt(arr.reduce((s, v) => s + v * v, 0));
      if (norm > 0) for (let i = 0; i < dim; i++) arr[i] /= norm;
      return arr;
    },
  };
}

describe('handleSaveInsight', () => {
  it('saves and retrieves an insight', async () => {
    const { store, db, tmpDir } = makeStore();
    const embedder = makeMockEmbedder();

    const result = await handleSaveInsight(
      {
        content: 'Use dependency injection for testability',
        wing: 'myproject',
        room: 'arch',
      },
      { vecStore: store, embedder },
    );

    expect(result.id).toBeTruthy();
    expect(result.content).toBe('Use dependency injection for testability');
    expect(result.wing).toBe('myproject');
    expect(result.room).toBe('arch');
    expect(result.importance).toBe(3);
    expect(result.duplicateWarning).toBeUndefined();
    expect(store.countInsights()).toBe(1);

    db.close();
    rmSync(tmpDir, { recursive: true });
  });

  it('warns on duplicate insight', async () => {
    const { store, db, tmpDir } = makeStore();
    // Use embedder that returns same vector for same text
    const staticEmbedder: EmbeddingClient = {
      dimension: 768,
      model: 'static',
      embed: async () => {
        const arr = new Float32Array(768).fill(0.036);
        const norm = Math.sqrt(arr.reduce((s, v) => s + v * v, 0));
        for (let i = 0; i < 768; i++) arr[i] /= norm;
        return arr;
      },
    };

    await handleSaveInsight(
      { content: 'first insight' },
      { vecStore: store, embedder: staticEmbedder },
    );
    const result = await handleSaveInsight(
      { content: 'duplicate insight' },
      { vecStore: store, embedder: staticEmbedder },
    );

    expect(result.duplicateWarning).toBeTruthy();
    expect(result.duplicateWarning).toContain('Similar insight already exists');
    // Still saves despite warning
    expect(store.countInsights()).toBe(2);

    db.close();
    rmSync(tmpDir, { recursive: true });
  });

  it('throws when no embedding support and no database', async () => {
    await expect(
      handleSaveInsight(
        { content: 'test' },
        { vecStore: null, embedder: null },
      ),
    ).rejects.toThrow('embedding support or a database');
  });

  it('saves text-only insight when no embedding deps', async () => {
    const tmpDir = mkdtempSync(join(tmpdir(), 'insight-textonly-'));
    const db = new Database(join(tmpDir, 'test.sqlite'));

    const result = await handleSaveInsight(
      { content: 'text-only insight', wing: 'project-x', importance: 4 },
      { db },
    );

    expect(result.id).toBeTruthy();
    expect(result.content).toBe('text-only insight');
    expect(result.wing).toBe('project-x');
    expect(result.importance).toBe(4);
    expect(result.warning).toContain('without embedding');
    expect(result.duplicateWarning).toBeUndefined();

    // Verify it's in the insights table
    const rows = db.listInsightsByWing('project-x', 10);
    expect(rows).toHaveLength(1);
    expect(rows[0].content).toBe('text-only insight');
    expect(rows[0].has_embedding).toBe(0);

    db.close();
    rmSync(tmpDir, { recursive: true });
  });

  it('respects custom importance', async () => {
    const { store, db, tmpDir } = makeStore();
    const embedder = makeMockEmbedder();

    const result = await handleSaveInsight(
      { content: 'critical decision', importance: 5 },
      { vecStore: store, embedder },
    );

    expect(result.importance).toBe(5);

    db.close();
    rmSync(tmpDir, { recursive: true });
  });
});
