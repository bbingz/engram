import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { Database } from '../../src/core/db.js';
import { EmbeddingIndexer } from '../../src/core/embedding-indexer.js';
import type { EmbeddingClient } from '../../src/core/embeddings.js';
import type { VectorStore } from '../../src/core/vector-store.js';
import { SqliteVecStore } from '../../src/core/vector-store.js';

describe('EmbeddingIndexer', () => {
  let db: Database;
  let tmpDir: string;
  let mockStore: VectorStore;
  let mockClient: EmbeddingClient;
  let indexer: EmbeddingIndexer;

  beforeEach(() => {
    tmpDir = mkdtempSync(join(tmpdir(), 'embed-idx-test-'));
    db = new Database(join(tmpDir, 'test.sqlite'));

    mockStore = {
      upsert: vi.fn(),
      search: vi.fn().mockReturnValue([]),
      delete: vi.fn(),
      count: vi.fn().mockReturnValue(0),
      upsertChunks: vi.fn(),
      searchChunks: vi.fn().mockReturnValue([]),
      deleteChunksBySession: vi.fn(),
      upsertInsight: vi.fn(),
      searchInsights: vi.fn().mockReturnValue([]),
      deleteInsight: vi.fn(),
      countInsights: vi.fn().mockReturnValue(0),
      activeModel: vi.fn().mockReturnValue(null),
      dropAndRebuild: vi.fn(),
    };

    mockClient = {
      embed: vi.fn().mockResolvedValue(new Float32Array(768).fill(0.1)),
      dimension: 768,
      model: 'mock',
    };

    indexer = new EmbeddingIndexer(db, mockStore, mockClient);
  });

  afterEach(() => {
    db.close();
    rmSync(tmpDir, { recursive: true });
  });

  it('indexes a session that has FTS content', async () => {
    db.upsertSession({
      id: 's1',
      source: 'codex',
      startTime: '2026-01-01T10:00:00Z',
      cwd: '/p',
      messageCount: 5,
      userMessageCount: 2,
      assistantMessageCount: 0,
      toolMessageCount: 0,
      systemMessageCount: 0,
      filePath: '/f1',
      sizeBytes: 100,
    });
    db.indexSessionContent('s1', [
      { role: 'user', content: 'Help me fix the login bug' },
    ]);

    const count = await indexer.indexAll();
    expect(count).toBe(1);
    expect(mockClient.embed).toHaveBeenCalledOnce();
    expect(mockStore.upsert).toHaveBeenCalledOnce();
  });

  it('skips sessions without FTS content', async () => {
    db.upsertSession({
      id: 's1',
      source: 'codex',
      startTime: '2026-01-01T10:00:00Z',
      cwd: '/p',
      messageCount: 0,
      userMessageCount: 0,
      assistantMessageCount: 0,
      toolMessageCount: 0,
      systemMessageCount: 0,
      filePath: '/f1',
      sizeBytes: 100,
    });
    // No indexSessionContent call - no FTS data

    const count = await indexer.indexAll();
    expect(count).toBe(0);
    expect(mockClient.embed).not.toHaveBeenCalled();
  });

  it('skips already-indexed sessions on second call', async () => {
    db.upsertSession({
      id: 's1',
      source: 'codex',
      startTime: '2026-01-01T10:00:00Z',
      cwd: '/p',
      messageCount: 5,
      userMessageCount: 2,
      assistantMessageCount: 0,
      toolMessageCount: 0,
      systemMessageCount: 0,
      filePath: '/f1',
      sizeBytes: 100,
    });
    db.indexSessionContent('s1', [
      { role: 'user', content: 'Hello world test' },
    ]);

    await indexer.indexAll();
    vi.mocked(mockClient.embed).mockClear();
    vi.mocked(mockStore.upsert).mockClear();

    const count = await indexer.indexAll();
    expect(count).toBe(0);
    expect(mockClient.embed).not.toHaveBeenCalled();
  });

  it('indexOne indexes a single session', async () => {
    db.upsertSession({
      id: 's1',
      source: 'codex',
      startTime: '2026-01-01T10:00:00Z',
      cwd: '/p',
      messageCount: 5,
      userMessageCount: 2,
      assistantMessageCount: 0,
      toolMessageCount: 0,
      systemMessageCount: 0,
      filePath: '/f1',
      sizeBytes: 100,
    });
    db.indexSessionContent('s1', [
      { role: 'user', content: 'Fix the auth bug' },
    ]);

    const result = await indexer.indexOne('s1');
    expect(result).toBe(true);
    expect(mockStore.upsert).toHaveBeenCalledOnce();
  });

  it('bounds the in-memory indexed-session cache loaded from the database', async () => {
    db.raw.exec(
      'CREATE TABLE session_embeddings(session_id TEXT PRIMARY KEY, model TEXT)',
    );
    const insert = db.raw.prepare(
      'INSERT INTO session_embeddings(session_id, model) VALUES (?, ?)',
    );
    for (let i = 0; i < 10_050; i++) {
      insert.run(`s-${i}`, 'mock');
    }

    await indexer.indexAll();

    expect((indexer as unknown as { indexed: Set<string> }).indexed.size).toBe(
      10_000,
    );
  });

  it('does not re-embed DB-backed sessions after the in-memory cache evicts them', async () => {
    const cacheConfig = EmbeddingIndexer as unknown as {
      MAX_INDEXED_CACHE: number;
    };
    const originalMaxIndexedCache = cacheConfig.MAX_INDEXED_CACHE;
    cacheConfig.MAX_INDEXED_CACHE = 2;

    try {
      db.raw.exec(
        'CREATE TABLE session_embeddings(session_id TEXT PRIMARY KEY, model TEXT)',
      );

      for (let i = 0; i < 3; i++) {
        const id = `s-${i}`;
        db.upsertSession({
          id,
          source: 'codex',
          startTime: '2026-01-01T10:00:00Z',
          cwd: '/p',
          messageCount: 2,
          userMessageCount: 1,
          assistantMessageCount: 1,
          toolMessageCount: 0,
          systemMessageCount: 0,
          filePath: `/f-${i}`,
          sizeBytes: 100,
        });
        db.indexSessionContent(id, [
          { role: 'user', content: `Embedding content ${i}` },
        ]);
        db.raw
          .prepare(
            'INSERT INTO session_embeddings(session_id, model) VALUES (?, ?)',
          )
          .run(id, 'mock');
      }

      const count = await indexer.indexAll();

      expect(count).toBe(0);
      expect(mockClient.embed).not.toHaveBeenCalled();
    } finally {
      cacheConfig.MAX_INDEXED_CACHE = originalMaxIndexedCache;
    }
  });

  it('persists embeddings through the real sqlite vector store and skips them after restart', async () => {
    const dbPath = join(tmpDir, 'integration.sqlite');
    db.close();
    db = new Database(dbPath);
    const store = new SqliteVecStore(db.raw);
    const embedCalls: string[] = [];
    const client: EmbeddingClient = {
      dimension: 768,
      model: 'deterministic-test-model',
      embed: vi.fn(async (text: string) => {
        embedCalls.push(text);
        return new Float32Array(768).fill(text.includes('restart') ? 0.7 : 0.2);
      }),
    };

    db.upsertSession({
      id: 'persisted-session',
      source: 'codex',
      startTime: '2026-01-01T10:00:00Z',
      cwd: '/p',
      messageCount: 3,
      userMessageCount: 1,
      assistantMessageCount: 1,
      toolMessageCount: 0,
      systemMessageCount: 0,
      filePath: '/f1',
      sizeBytes: 100,
    });
    db.indexSessionContent('persisted-session', [
      { role: 'user', content: 'restart-safe embedding content' },
    ]);

    const firstIndexer = new EmbeddingIndexer(db, store, client);
    expect(await firstIndexer.indexAll()).toBe(1);
    expect(store.count()).toBe(1);
    expect(store.search(new Float32Array(768).fill(0.7), 1)[0]?.sessionId).toBe(
      'persisted-session',
    );
    expect(
      db.raw
        .prepare('SELECT model FROM session_embeddings WHERE session_id = ?')
        .pluck()
        .get('persisted-session'),
    ).toBe('deterministic-test-model');

    db.close();
    db = new Database(dbPath);
    const restartedStore = new SqliteVecStore(db.raw);
    const restartedIndexer = new EmbeddingIndexer(db, restartedStore, client);
    vi.mocked(client.embed).mockClear();

    expect(await restartedIndexer.indexAll()).toBe(0);
    expect(client.embed).not.toHaveBeenCalled();
    expect(embedCalls).toHaveLength(1);
    expect(restartedStore.count()).toBe(1);
  });
});
