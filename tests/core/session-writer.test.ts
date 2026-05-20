import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { Database } from '../../src/core/db.js';
import { SessionSnapshotWriter } from '../../src/core/session-writer.js';

describe('SessionSnapshotWriter', () => {
  let db: Database;
  let tmpDir: string;

  beforeEach(() => {
    tmpDir = mkdtempSync(join(tmpdir(), 'session-writer-test-'));
    db = new Database(join(tmpDir, 'test.sqlite'));
  });

  afterEach(() => {
    db.close();
    rmSync(tmpDir, { recursive: true });
  });

  it('persists merged snapshot and durable jobs in one write path', () => {
    const writer = new SessionSnapshotWriter(db);

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
    });

    expect(db.getSession('sess-1')?.summary).toBe('hello');
    expect(
      db
        .listIndexJobs('sess-1')
        .map((j) => j.jobKind)
        .sort(),
    ).toEqual(['embedding', 'fts']);
  });

  it('returns noop and does not create duplicate jobs for identical payloads', () => {
    const writer = new SessionSnapshotWriter(db);
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
    };

    writer.writeAuthoritativeSnapshot(snapshot);
    const second = writer.writeAuthoritativeSnapshot(snapshot);

    expect(second.action).toBe('noop');
    expect(db.listIndexJobs('sess-1')).toHaveLength(2);
  });

  describe('tier-gated job dispatch', () => {
    it('skip tier → 0 index jobs', () => {
      const writer = new SessionSnapshotWriter(db);

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
      });

      expect(db.listIndexJobs('sess-skip')).toHaveLength(0);
    });

    it('lite tier → FTS job only', () => {
      const writer = new SessionSnapshotWriter(db);

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
      });

      const jobs = db.listIndexJobs('sess-lite').map((j) => j.jobKind);
      expect(jobs).toEqual(['fts']);
    });

    it('normal tier → FTS + embedding jobs', () => {
      const writer = new SessionSnapshotWriter(db);

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
      });

      const jobs = db
        .listIndexJobs('sess-normal')
        .map((j) => j.jobKind)
        .sort();
      expect(jobs).toEqual(['embedding', 'fts']);
    });

    it('premium tier → FTS + embedding jobs', () => {
      const writer = new SessionSnapshotWriter(db);

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
      });

      const jobs = db
        .listIndexJobs('sess-premium')
        .map((j) => j.jobKind)
        .sort();
      expect(jobs).toEqual(['embedding', 'fts']);
    });
  });

  describe('file_path fallback', () => {
    const baseSnapshot = (id: string, syncVersion: number, hash: string) => ({
      id,
      source: 'codex' as const,
      authoritativeNode: 'node-a',
      syncVersion,
      snapshotHash: hash,
      indexedAt: '2026-04-20T12:00:00Z',
      sourceLocator: '/tmp/foo.jsonl',
      startTime: '2026-04-20T11:00:00Z',
      cwd: '/repo',
      messageCount: 2,
      userMessageCount: 1,
      assistantMessageCount: 1,
      toolMessageCount: 0,
      systemMessageCount: 0,
      summary: 'unique',
    });

    it('first INSERT populates file_path from sourceLocator when local state is absent', () => {
      const writer = new SessionSnapshotWriter(db);
      writer.writeAuthoritativeSnapshot(baseSnapshot('s1', 1, 'h1'));

      const row = db
        .getRawDb()
        .prepare('SELECT file_path FROM sessions WHERE id = ?')
        .get('s1') as { file_path: string | null };
      expect(row.file_path).toBe('/tmp/foo.jsonl');
    });

    it('ON CONFLICT UPDATE heals an empty file_path using source_locator', () => {
      const writer = new SessionSnapshotWriter(db);
      writer.writeAuthoritativeSnapshot(baseSnapshot('s2', 1, 'h1'));

      // simulate legacy-bug state: file_path got stored empty
      db.getRawDb()
        .prepare('UPDATE sessions SET file_path = ? WHERE id = ?')
        .run('', 's2');

      // next upsert with a bumped version triggers the UPDATE branch
      writer.writeAuthoritativeSnapshot(baseSnapshot('s2', 2, 'h2'));

      const row = db
        .getRawDb()
        .prepare('SELECT file_path FROM sessions WHERE id = ?')
        .get('s2') as { file_path: string | null };
      expect(row.file_path).toBe('/tmp/foo.jsonl');
    });

    it('ON CONFLICT UPDATE does not overwrite an existing non-empty file_path', () => {
      const writer = new SessionSnapshotWriter(db);
      writer.writeAuthoritativeSnapshot(baseSnapshot('s3', 1, 'h1'));

      // set an explicit local path (what backfillFilePaths or real Swift reader would pick)
      db.getRawDb()
        .prepare('UPDATE sessions SET file_path = ? WHERE id = ?')
        .run('/real/local/path.jsonl', 's3');

      writer.writeAuthoritativeSnapshot(baseSnapshot('s3', 2, 'h2'));

      const row = db
        .getRawDb()
        .prepare('SELECT file_path FROM sessions WHERE id = ?')
        .get('s3') as { file_path: string | null };
      expect(row.file_path).toBe('/real/local/path.jsonl');
    });

    it('sync:// source_locator does not leak into file_path', () => {
      const writer = new SessionSnapshotWriter(db);
      const snap = baseSnapshot('s4', 1, 'h1');
      snap.sourceLocator = 'sync://peer/abc';
      writer.writeAuthoritativeSnapshot(snap);

      const row = db
        .getRawDb()
        .prepare('SELECT file_path, source_locator FROM sessions WHERE id = ?')
        .get('s4') as { file_path: string | null; source_locator: string };
      expect(row.source_locator).toBe('sync://peer/abc');
      // file_path must stay empty/null — we do not want sync:// URIs on the read path
      expect(row.file_path === '' || row.file_path === null).toBe(true);
    });
  });

  it('enqueues fresh content-hash jobs when same sync version changes content', () => {
    const writer = new SessionSnapshotWriter(db);
    const snapshot = {
      id: 'sess-hash',
      source: 'codex' as const,
      authoritativeNode: 'node-a',
      syncVersion: 1,
      snapshotHash: 'hash-1',
      indexedAt: '2026-04-20T12:00:00Z',
      sourceLocator: '/tmp/hash.jsonl',
      startTime: '2026-04-20T11:00:00Z',
      cwd: '/repo',
      messageCount: 2,
      userMessageCount: 1,
      assistantMessageCount: 1,
      toolMessageCount: 0,
      systemMessageCount: 0,
      summary: 'old summary',
      tier: 'normal' as const,
    };

    writer.writeAuthoritativeSnapshot(snapshot);
    db.getRawDb()
      .prepare(
        "UPDATE session_index_jobs SET status = 'completed' WHERE session_id = ?",
      )
      .run('sess-hash');
    writer.writeAuthoritativeSnapshot({
      ...snapshot,
      snapshotHash: 'hash-2',
      sizeBytes: 256,
      summary: 'new summary',
    });

    expect(
      db
        .listIndexJobs('sess-hash')
        .filter((j) => j.status === 'pending')
        .map((j) => j.id)
        .sort(),
    ).toEqual(['sess-hash:1:hash-2:embedding', 'sess-hash:1:hash-2:fts']);
  });

  it('deletes stale search artifacts when a normal session is downgraded to skip', () => {
    const writer = new SessionSnapshotWriter(db);
    const snapshot = {
      id: 'sess-downgrade',
      source: 'codex' as const,
      authoritativeNode: 'node-a',
      syncVersion: 1,
      snapshotHash: 'hash-1',
      indexedAt: '2026-04-20T12:00:00Z',
      sourceLocator: '/tmp/downgrade.jsonl',
      startTime: '2026-04-20T11:00:00Z',
      cwd: '/repo',
      messageCount: 2,
      userMessageCount: 1,
      assistantMessageCount: 1,
      toolMessageCount: 0,
      systemMessageCount: 0,
      summary: 'visible summary',
      tier: 'normal' as const,
    };

    writer.writeAuthoritativeSnapshot(snapshot);
    db.replaceFtsContent('sess-downgrade', ['old searchable content']);
    db.getRawDb()
      .prepare(
        'CREATE TABLE IF NOT EXISTS session_embeddings(session_id TEXT PRIMARY KEY)',
      )
      .run();
    db.getRawDb()
      .prepare('INSERT INTO session_embeddings(session_id) VALUES (?)')
      .run('sess-downgrade');

    writer.writeAuthoritativeSnapshot({
      ...snapshot,
      snapshotHash: 'hash-2',
      tier: 'skip',
    });

    expect(db.getFtsContent('sess-downgrade')).toEqual([]);
    expect(
      db
        .getRawDb()
        .prepare(
          'SELECT COUNT(*) AS count FROM session_embeddings WHERE session_id = ?',
        )
        .get('sess-downgrade'),
    ).toEqual({ count: 0 });
    expect(
      db.listIndexJobs('sess-downgrade').filter((j) => j.status === 'pending'),
    ).toEqual([]);
  });
});
