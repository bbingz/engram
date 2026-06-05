import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { Database } from '../../src/core/db.js';
import type { EmbeddingClient } from '../../src/core/embeddings.js';
import { IndexJobRunner } from '../../src/core/index-job-runner.js';
import type { VectorStore } from '../../src/core/vector-store.js';

describe('IndexJobRunner', () => {
  let db: Database;
  let tmpDir: string;
  let mockStore: VectorStore;
  let mockClient: EmbeddingClient;

  beforeEach(() => {
    tmpDir = mkdtempSync(join(tmpdir(), 'index-job-runner-test-'));
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
  });

  afterEach(() => {
    db.close();
    rmSync(tmpDir, { recursive: true });
  });

  it('marks embedding jobs completed after successful vector upsert', async () => {
    db.upsertAuthoritativeSnapshot({
      id: 'sess-1',
      source: 'codex',
      authoritativeNode: 'local',
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
    });
    db.setLocalReadablePath('sess-1', '/tmp/rollout.jsonl');
    db.insertIndexJobs('sess-1', 1, ['fts', 'embedding']);

    const runner = new IndexJobRunner(db, mockStore, mockClient);
    await runner.runRecoverableJobs();

    expect(
      db.listIndexJobs('sess-1').every((j) => j.status === 'completed'),
    ).toBe(true);
    expect(mockStore.upsert).toHaveBeenCalledOnce();
  });

  it('marks embedding jobs not_applicable for metadata-only replicas', async () => {
    db.upsertAuthoritativeSnapshot({
      id: 'sess-2',
      source: 'codex',
      authoritativeNode: 'peer-a',
      syncVersion: 1,
      snapshotHash: 'hash-2',
      indexedAt: '2026-03-18T12:00:00Z',
      sourceLocator: 'sync://peer-a/sess-2.jsonl',
      startTime: '2026-03-18T11:00:00Z',
      cwd: '/repo',
      messageCount: 2,
      userMessageCount: 1,
      assistantMessageCount: 1,
      toolMessageCount: 0,
      systemMessageCount: 0,
      summary: 'remote summary',
    });
    db.insertIndexJobs('sess-2', 1, ['fts', 'embedding']);

    const runner = new IndexJobRunner(db, mockStore, mockClient);
    await runner.runRecoverableJobs();

    const jobs = db.listIndexJobs('sess-2');
    expect(jobs.find((j) => j.jobKind === 'fts')?.status).toBe('completed');
    expect(jobs.find((j) => j.jobKind === 'embedding')?.status).toBe(
      'not_applicable',
    );
  });

  it('rebuilds FTS content for content-hash targeted jobs', async () => {
    db.upsertAuthoritativeSnapshot({
      id: 'sess-3',
      source: 'codex',
      authoritativeNode: 'local',
      syncVersion: 1,
      snapshotHash: 'hash-2',
      indexedAt: '2026-03-18T12:00:00Z',
      sourceLocator: '/tmp/rollout.jsonl',
      startTime: '2026-03-18T11:00:00Z',
      cwd: '/repo',
      messageCount: 2,
      userMessageCount: 1,
      assistantMessageCount: 1,
      toolMessageCount: 0,
      systemMessageCount: 0,
      summary: 'new searchable summary',
    });
    db.replaceFtsContent('sess-3', ['old searchable summary']);
    db.insertIndexJobs('sess-3', 1, ['fts'], 'hash-2');

    const runner = new IndexJobRunner(db, mockStore, mockClient);
    await runner.runRecoverableJobs();

    expect(db.getFtsContent('sess-3')).toEqual(['new searchable summary']);
    expect(db.listIndexJobs('sess-3')[0]?.status).toBe('completed');
  });

  it('finalizes a pending FTS rebuild after the last FTS job completes', async () => {
    db.upsertAuthoritativeSnapshot({
      id: 'sess-finalize',
      source: 'codex',
      authoritativeNode: 'local',
      syncVersion: 1,
      snapshotHash: 'hash-finalize',
      indexedAt: '2026-03-18T12:00:00Z',
      sourceLocator: '/tmp/rollout.jsonl',
      startTime: '2026-03-18T11:00:00Z',
      cwd: '/repo',
      messageCount: 1,
      userMessageCount: 1,
      assistantMessageCount: 0,
      toolMessageCount: 0,
      systemMessageCount: 0,
      summary: 'final active text',
    });
    db.replaceFtsContent('sess-finalize', ['final active text']);
    db.setMetadata('fts_version', '2');
    db.setMetadata('fts_rebuild_version', '3');
    db.raw.exec(`
      CREATE VIRTUAL TABLE sessions_fts_rebuild USING fts5(
        session_id UNINDEXED,
        content,
        tokenize='trigram case_sensitive 0'
      );
      INSERT INTO sessions_fts_rebuild(session_id, content)
      VALUES ('sess-finalize', 'final active text');
    `);
    db.insertIndexJobs('sess-finalize', 1, ['fts']);

    const runner = new IndexJobRunner(db, mockStore, mockClient);
    await runner.runRecoverableJobs();

    expect(db.getMetadata('fts_version')).toBe('3');
    expect(db.getMetadata('fts_rebuild_version')).toBeNull();
    expect(db.getFtsContent('sess-finalize')).toEqual(['final active text']);
    expect(
      db.raw
        .prepare(
          "SELECT name FROM sqlite_master WHERE type='table' AND name='sessions_fts_rebuild'",
        )
        .get(),
    ).toBeUndefined();
  });

  it('preserves copied active FTS rows when reopened jobs only mark completed', async () => {
    db.upsertAuthoritativeSnapshot({
      id: 'sess-copy',
      source: 'codex',
      authoritativeNode: 'local',
      syncVersion: 1,
      snapshotHash: 'hash-copy',
      indexedAt: '2026-03-18T12:00:00Z',
      sourceLocator: '/tmp/rollout.jsonl',
      startTime: '2026-03-18T11:00:00Z',
      cwd: '/repo',
      messageCount: 1,
      userMessageCount: 1,
      assistantMessageCount: 0,
      toolMessageCount: 0,
      systemMessageCount: 0,
      summary: 'summary fallback',
    });
    db.replaceFtsContent('sess-copy', ['full copied transcript text']);
    db.setMetadata('fts_version', '2');
    db.setMetadata('fts_rebuild_version', '3');
    db.raw.exec(`
      CREATE VIRTUAL TABLE sessions_fts_rebuild USING fts5(
        session_id UNINDEXED,
        content,
        tokenize='trigram case_sensitive 0'
      );
      INSERT INTO sessions_fts_rebuild(session_id, content)
      VALUES ('sess-copy', 'full copied transcript text');
    `);
    db.insertIndexJobs('sess-copy', 1, ['fts']);

    const runner = new IndexJobRunner(db, mockStore, mockClient);
    await runner.runRecoverableJobs();

    expect(db.getFtsContent('sess-copy')).toEqual([
      'full copied transcript text',
    ]);
    expect(
      db.raw
        .prepare(
          'SELECT COUNT(*) AS count FROM sessions_fts WHERE session_id = ?',
        )
        .get('sess-copy'),
    ).toEqual({ count: 1 });
  });
});
