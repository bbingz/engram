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
    expect(result.importance).toBe(5);
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
        { content: 'test insight content' },
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

  it('falls back to text-only when embedder returns null', async () => {
    const { store, db: sqliteDb, tmpDir } = makeStore();
    const engDb = new Database(join(tmpDir, 'engram.sqlite'));
    const nullEmbedder: EmbeddingClient = {
      dimension: 768,
      model: 'null-model',
      embed: async () => null,
    };

    const result = await handleSaveInsight(
      { content: 'embed-fail insight', wing: 'proj' },
      { vecStore: store, embedder: nullEmbedder, db: engDb },
    );

    expect(result.id).toBeTruthy();
    expect(result.content).toBe('embed-fail insight');
    expect(result.warning).toContain('Embedding generation failed');
    // Not saved in vector store
    expect(store.countInsights()).toBe(0);
    // Saved in text DB
    const rows = engDb.listInsightsByWing('proj', 10);
    expect(rows).toHaveLength(1);
    expect(rows[0].has_embedding).toBe(0);

    sqliteDb.close();
    engDb.close();
    rmSync(tmpDir, { recursive: true });
  });

  it('dual-writes to both vector store and text DB', async () => {
    const { store, db: sqliteDb, tmpDir } = makeStore();
    const engDb = new Database(join(tmpDir, 'engram.sqlite'));
    const embedder = makeMockEmbedder();

    const result = await handleSaveInsight(
      { content: 'dual-write test', wing: 'proj' },
      { vecStore: store, embedder, db: engDb },
    );

    expect(result.id).toBeTruthy();
    expect(result.warning).toBeUndefined();
    expect(store.countInsights()).toBe(1);
    const rows = engDb.listInsightsByWing('proj', 10);
    expect(rows).toHaveLength(1);
    expect(rows[0].has_embedding).toBe(1);

    sqliteDb.close();
    engDb.close();
    rmSync(tmpDir, { recursive: true });
  });

  it('accepts importance boundary 0', async () => {
    const tmpDir = mkdtempSync(join(tmpdir(), 'insight-imp0-'));
    const db = new Database(join(tmpDir, 'test.sqlite'));

    const result = await handleSaveInsight(
      { content: 'trivial note', importance: 0 },
      { db },
    );

    expect(result.importance).toBe(0);

    db.close();
    rmSync(tmpDir, { recursive: true });
  });

  it('rejects empty content', async () => {
    await expect(handleSaveInsight({ content: '' }, {})).rejects.toThrow(
      'Content cannot be empty.',
    );
  });

  it('rejects whitespace-only content', async () => {
    await expect(
      handleSaveInsight({ content: '   \n\t  ' }, {}),
    ).rejects.toThrow('Content cannot be empty.');
  });

  it('rejects content shorter than 10 characters', async () => {
    await expect(
      handleSaveInsight({ content: 'too short' }, {}),
    ).rejects.toThrow('Content too short (9 chars, minimum 10).');
  });

  it('rejects content longer than 50,000 characters', async () => {
    const longContent = 'a'.repeat(50_001);
    await expect(
      handleSaveInsight({ content: longContent }, {}),
    ).rejects.toThrow('Content too long (50001 chars, maximum 50,000).');
  });

  it('trims content whitespace before saving', async () => {
    const tmpDir = mkdtempSync(join(tmpdir(), 'insight-trim-'));
    const db = new Database(join(tmpDir, 'test.sqlite'));

    const result = await handleSaveInsight(
      { content: '  trimmed insight content  ' },
      { db },
    );

    expect(result.content).toBe('trimmed insight content');

    db.close();
    rmSync(tmpDir, { recursive: true });
  });

  it('trims and truncates wing and room', async () => {
    const tmpDir = mkdtempSync(join(tmpdir(), 'insight-wingtrim-'));
    const db = new Database(join(tmpDir, 'test.sqlite'));
    const longWing = 'w'.repeat(300);
    const longRoom = 'r'.repeat(300);

    const result = await handleSaveInsight(
      {
        content: 'insight with long wing',
        wing: `  ${longWing}  `,
        room: `  ${longRoom}  `,
      },
      { db },
    );

    expect(result.wing).toHaveLength(200);
    expect(result.room).toHaveLength(200);

    db.close();
    rmSync(tmpDir, { recursive: true });
  });

  it('passes source_session_id through to text DB', async () => {
    const tmpDir = mkdtempSync(join(tmpdir(), 'insight-sessid-'));
    const db = new Database(join(tmpDir, 'test.sqlite'));

    const result = await handleSaveInsight(
      {
        content: 'insight with session link',
        wing: 'proj',
        source_session_id: 'sess-abc-123',
      },
      { db },
    );

    expect(result.id).toBeTruthy();
    const rows = db.listInsightsByWing('proj', 10);
    expect(rows).toHaveLength(1);
    expect(rows[0].source_session_id).toBe('sess-abc-123');

    db.close();
    rmSync(tmpDir, { recursive: true });
  });

  it('passes source_session_id through to vector store and text DB', async () => {
    const { store, db: sqliteDb, tmpDir } = makeStore();
    const engDb = new Database(join(tmpDir, 'engram.sqlite'));
    const embedder = makeMockEmbedder();

    const result = await handleSaveInsight(
      {
        content: 'dual-write insight with session',
        wing: 'proj',
        source_session_id: 'sess-xyz-789',
      },
      { vecStore: store, embedder, db: engDb },
    );

    expect(result.id).toBeTruthy();
    expect(store.countInsights()).toBe(1);
    const rows = engDb.listInsightsByWing('proj', 10);
    expect(rows).toHaveLength(1);
    expect(rows[0].source_session_id).toBe('sess-xyz-789');

    sqliteDb.close();
    engDb.close();
    rmSync(tmpDir, { recursive: true });
  });

  it('accepts importance boundary 5', async () => {
    const tmpDir = mkdtempSync(join(tmpdir(), 'insight-imp5-'));
    const db = new Database(join(tmpDir, 'test.sqlite'));

    const result = await handleSaveInsight(
      { content: 'critical insight', importance: 5 },
      { db },
    );

    expect(result.importance).toBe(5);

    db.close();
    rmSync(tmpDir, { recursive: true });
  });

  it('deleteInsightText removes from insights and insights_fts (text-only)', async () => {
    const tmpDir = mkdtempSync(join(tmpdir(), 'insight-del-text-'));
    const db = new Database(join(tmpDir, 'test.sqlite'));

    const result = await handleSaveInsight(
      { content: 'insight to delete', wing: 'proj' },
      { db },
    );

    // Verify it exists
    expect(db.listInsightsByWing('proj', 10)).toHaveLength(1);
    expect(db.searchInsightsFts('delete', 10).length).toBeGreaterThan(0);

    // Delete it
    const deleted = db.deleteInsightText(result.id);
    expect(deleted).toBe(true);

    // Verify both tables are clean
    expect(db.listInsightsByWing('proj', 10)).toHaveLength(0);
    expect(db.searchInsightsFts('delete', 10)).toHaveLength(0);

    // Deleting again returns false
    expect(db.deleteInsightText(result.id)).toBe(false);

    db.close();
    rmSync(tmpDir, { recursive: true });
  });

  it('text-only dedup: second identical save returns duplicateWarning', async () => {
    const tmpDir = mkdtempSync(join(tmpdir(), 'insight-dedup-'));
    const db = new Database(join(tmpDir, 'test.sqlite'));

    const first = await handleSaveInsight(
      { content: 'text-only dedup test content', wing: 'proj' },
      { db },
    );
    expect(first.warning).toContain('without embedding');
    expect(first.duplicateWarning).toBeUndefined();

    const second = await handleSaveInsight(
      { content: 'text-only dedup test content', wing: 'proj' },
      { db },
    );
    expect(second.duplicateWarning).toContain(
      'Duplicate insight already exists',
    );
    expect(second.id).toBe(first.id);
    // Only one row in DB
    expect(db.listInsightsByWing('proj', 10)).toHaveLength(1);

    db.close();
    rmSync(tmpDir, { recursive: true });
  });

  it('text-only dedup: catches different casing as duplicate', async () => {
    const tmpDir = mkdtempSync(join(tmpdir(), 'insight-dedup-case-'));
    const db = new Database(join(tmpDir, 'test.sqlite'));

    await handleSaveInsight(
      { content: 'Test Insight Content here', wing: 'proj' },
      { db },
    );

    const second = await handleSaveInsight(
      { content: 'test insight content here', wing: 'proj' },
      { db },
    );
    expect(second.duplicateWarning).toContain(
      'Duplicate insight already exists',
    );
    expect(db.listInsightsByWing('proj', 10)).toHaveLength(1);

    db.close();
    rmSync(tmpDir, { recursive: true });
  });

  it('text-only dedup: same content in different wings both succeed', async () => {
    const tmpDir = mkdtempSync(join(tmpdir(), 'insight-dedup-wing-'));
    const db = new Database(join(tmpDir, 'test.sqlite'));

    const first = await handleSaveInsight(
      { content: 'shared insight content', wing: 'project-a' },
      { db },
    );
    expect(first.duplicateWarning).toBeUndefined();

    const second = await handleSaveInsight(
      { content: 'shared insight content', wing: 'project-b' },
      { db },
    );
    expect(second.duplicateWarning).toBeUndefined();
    expect(second.id).not.toBe(first.id);

    // Both saved
    expect(db.listInsightsByWing('project-a', 10)).toHaveLength(1);
    expect(db.listInsightsByWing('project-b', 10)).toHaveLength(1);

    db.close();
    rmSync(tmpDir, { recursive: true });
  });

  it('deleteInsightText + vecStore.deleteInsight cleans both stores', async () => {
    const { store, db: sqliteDb, tmpDir } = makeStore();
    const engDb = new Database(join(tmpDir, 'engram.sqlite'));
    const embedder = makeMockEmbedder();

    const result = await handleSaveInsight(
      { content: 'dual-write insight to delete', wing: 'proj' },
      { vecStore: store, embedder, db: engDb },
    );

    // Verify both stores have the insight
    expect(store.countInsights()).toBe(1);
    expect(engDb.listInsightsByWing('proj', 10)).toHaveLength(1);
    expect(engDb.searchInsightsFts('delete', 10).length).toBeGreaterThan(0);

    // Delete from both stores
    store.deleteInsight(result.id);
    const deleted = engDb.deleteInsightText(result.id);
    expect(deleted).toBe(true);

    // Verify clean
    expect(store.countInsights()).toBe(0);
    expect(engDb.listInsightsByWing('proj', 10)).toHaveLength(0);
    expect(engDb.searchInsightsFts('delete', 10)).toHaveLength(0);

    sqliteDb.close();
    engDb.close();
    rmSync(tmpDir, { recursive: true });
  });
});

describe('insight lifecycle', () => {
  it('full lifecycle: save → retrieve → delete → verify empty (text-only)', async () => {
    const tmpDir = mkdtempSync(join(tmpdir(), 'insight-lifecycle-'));
    const db = new Database(join(tmpDir, 'test.sqlite'));

    // 1. Save
    const result = await handleSaveInsight(
      {
        content: 'lifecycle test insight content',
        wing: 'lifecycle-proj',
        room: 'arch',
      },
      { db },
    );
    expect(result.id).toBeTruthy();
    expect(result.warning).toContain('without embedding');

    // 2. Retrieve via listInsightsByWing
    const byWing = db.listInsightsByWing('lifecycle-proj', 10);
    expect(byWing).toHaveLength(1);
    expect(byWing[0].content).toBe('lifecycle test insight content');
    expect(byWing[0].room).toBe('arch');

    // 2b. Retrieve via FTS
    const ftsHits = db.searchInsightsFts('lifecycle', 10);
    expect(ftsHits.length).toBeGreaterThan(0);
    expect(ftsHits[0].id).toBe(result.id);

    // 3. Delete
    const deleted = db.deleteInsightText(result.id);
    expect(deleted).toBe(true);

    // 4. Verify insights table is empty
    expect(db.listInsightsByWing('lifecycle-proj', 10)).toHaveLength(0);

    // 5. Verify insights_fts table is empty
    expect(db.searchInsightsFts('lifecycle', 10)).toHaveLength(0);

    db.close();
    rmSync(tmpDir, { recursive: true });
  });

  it('dual-store lifecycle: save → verify both stores → delete both → verify all clean', async () => {
    const { store, db: sqliteDb, tmpDir } = makeStore();
    const engDb = new Database(join(tmpDir, 'engram.sqlite'));
    const embedder = makeMockEmbedder();

    // 1. Save with vecStore + embedder + db (dual-write)
    const result = await handleSaveInsight(
      { content: 'dual-store lifecycle insight', wing: 'dual-proj' },
      { vecStore: store, embedder, db: engDb },
    );
    expect(result.id).toBeTruthy();
    expect(result.warning).toBeUndefined(); // no warning = full dual-write

    // 2. Verify it exists in both stores
    expect(store.countInsights()).toBe(1);
    const textRows = engDb.listInsightsByWing('dual-proj', 10);
    expect(textRows).toHaveLength(1);
    expect(textRows[0].has_embedding).toBe(1);
    expect(engDb.searchInsightsFts('lifecycle', 10).length).toBeGreaterThan(0);

    // 3. Delete from both stores
    store.deleteInsight(result.id);
    const deleted = engDb.deleteInsightText(result.id);
    expect(deleted).toBe(true);

    // 4. Verify all 4 tables are clean
    // memory_insights: countInsights checks deleted_at IS NULL
    expect(store.countInsights()).toBe(0);
    // vec_insights: implicitly clean (deleteInsight removes from vec_insights)
    // insights table
    expect(engDb.listInsightsByWing('dual-proj', 10)).toHaveLength(0);
    // insights_fts table
    expect(engDb.searchInsightsFts('lifecycle', 10)).toHaveLength(0);

    sqliteDb.close();
    engDb.close();
    rmSync(tmpDir, { recursive: true });
  });

  it('text-only dedup across lifecycle: save A, save A again (dup), save B, verify count', async () => {
    const tmpDir = mkdtempSync(join(tmpdir(), 'insight-lifecycle-dedup-'));
    const db = new Database(join(tmpDir, 'test.sqlite'));

    // 1. Save insight A
    const a1 = await handleSaveInsight(
      { content: 'insight alpha content here', wing: 'dedup-proj' },
      { db },
    );
    expect(a1.id).toBeTruthy();
    expect(a1.duplicateWarning).toBeUndefined();

    // 2. Save insight A again → get duplicateWarning, same id returned
    const a2 = await handleSaveInsight(
      { content: 'insight alpha content here', wing: 'dedup-proj' },
      { db },
    );
    expect(a2.duplicateWarning).toContain('Duplicate insight already exists');
    expect(a2.id).toBe(a1.id);

    // 3. Save insight B (different content) → success
    const b = await handleSaveInsight(
      { content: 'insight bravo different content', wing: 'dedup-proj' },
      { db },
    );
    expect(b.id).toBeTruthy();
    expect(b.duplicateWarning).toBeUndefined();
    expect(b.id).not.toBe(a1.id);

    // 4. Verify only 2 rows in insights table
    const all = db.listInsightsByWing('dedup-proj', 10);
    expect(all).toHaveLength(2);

    db.close();
    rmSync(tmpDir, { recursive: true });
  });

  it('FTS retrieval after save: finds matching content, misses nonexistent', async () => {
    const tmpDir = mkdtempSync(join(tmpdir(), 'insight-lifecycle-fts-'));
    const db = new Database(join(tmpDir, 'test.sqlite'));

    // 1. Save insight with specific content
    await handleSaveInsight(
      {
        content: 'kubernetes deployment strategy for production clusters',
        wing: 'infra',
      },
      { db },
    );

    // 2. Search via FTS for "kubernetes" → find it
    const hits = db.searchInsightsFts('kubernetes', 10);
    expect(hits).toHaveLength(1);
    expect(hits[0].content).toContain('kubernetes');
    expect(hits[0].wing).toBe('infra');

    // 3. Search for "nonexistent" → not found
    const misses = db.searchInsightsFts('nonexistent', 10);
    expect(misses).toHaveLength(0);

    db.close();
    rmSync(tmpDir, { recursive: true });
  });
});
