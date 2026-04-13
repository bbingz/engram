import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { reconcileInsights } from '../../src/core/db/maintenance.js';
import { Database } from '../../src/core/db.js';

describe('reconcileInsights', () => {
  let db: Database;
  let tmpDir: string;

  beforeEach(() => {
    tmpDir = mkdtempSync(join(tmpdir(), 'engram-maintenance-test-'));
    db = new Database(join(tmpDir, 'test.sqlite'));

    // Create memory_insights table (normally created by VectorStore when sqlite-vec is loaded)
    db.raw.exec(`
      CREATE TABLE IF NOT EXISTS memory_insights (
        id TEXT PRIMARY KEY,
        content TEXT NOT NULL,
        wing TEXT,
        room TEXT,
        source_session_id TEXT,
        importance INTEGER DEFAULT 5,
        model TEXT NOT NULL DEFAULT 'unknown',
        created_at TEXT DEFAULT (datetime('now')),
        deleted_at TEXT
      )
    `);
  });

  afterEach(() => {
    db.close();
    rmSync(tmpDir, { recursive: true });
  });

  it('resets has_embedding when memory_insights row is missing', () => {
    // Insert insight claiming has_embedding=1, but no memory_insights row
    db.raw
      .prepare(
        `INSERT INTO insights (id, content, has_embedding) VALUES ('ins-1', 'test insight', 1)`,
      )
      .run();

    const result = reconcileInsights(db.raw);

    expect(result.resetEmbedding).toBe(1);
    expect(result.orphanedVector).toBe(0);

    // Verify has_embedding is now 0
    const row = db.raw
      .prepare('SELECT has_embedding FROM insights WHERE id = ?')
      .get('ins-1') as { has_embedding: number };
    expect(row.has_embedding).toBe(0);
  });

  it('soft-deletes orphaned memory_insights rows', () => {
    // Insert memory_insights row with no matching insights row
    db.raw
      .prepare(
        `INSERT INTO memory_insights (id, content, model) VALUES ('orphan-1', 'orphaned vector', 'test-model')`,
      )
      .run();

    const result = reconcileInsights(db.raw);

    expect(result.resetEmbedding).toBe(0);
    expect(result.orphanedVector).toBe(1);

    // Verify soft-deleted
    const row = db.raw
      .prepare('SELECT deleted_at FROM memory_insights WHERE id = ?')
      .get('orphan-1') as { deleted_at: string | null };
    expect(row.deleted_at).not.toBeNull();
  });

  it('returns zeros when everything is consistent', () => {
    const insightId = 'consistent-1';

    // Insert matching rows in both tables
    db.raw
      .prepare(
        `INSERT INTO insights (id, content, has_embedding) VALUES (?, 'consistent insight', 1)`,
      )
      .run(insightId);
    db.raw
      .prepare(
        `INSERT INTO memory_insights (id, content, model) VALUES (?, 'consistent insight', 'test-model')`,
      )
      .run(insightId);

    const result = reconcileInsights(db.raw);

    expect(result.resetEmbedding).toBe(0);
    expect(result.orphanedVector).toBe(0);
  });

  it('skips gracefully when memory_insights table does not exist', () => {
    // Drop memory_insights to simulate sqlite-vec never loaded
    db.raw.exec('DROP TABLE memory_insights');

    // Insert insight with has_embedding=1 (stale flag)
    db.raw
      .prepare(
        `INSERT INTO insights (id, content, has_embedding) VALUES ('ins-no-vec', 'test', 1)`,
      )
      .run();

    const result = reconcileInsights(db.raw);

    expect(result.resetEmbedding).toBe(0);
    expect(result.orphanedVector).toBe(0);

    // has_embedding should remain unchanged (no crash)
    const row = db.raw
      .prepare('SELECT has_embedding FROM insights WHERE id = ?')
      .get('ins-no-vec') as { has_embedding: number };
    expect(row.has_embedding).toBe(1);
  });

  it('ignores already soft-deleted memory_insights rows', () => {
    // memory_insights row that is already soft-deleted should not affect reset
    db.raw
      .prepare(
        `INSERT INTO insights (id, content, has_embedding) VALUES ('ins-2', 'test', 1)`,
      )
      .run();
    db.raw
      .prepare(
        `INSERT INTO memory_insights (id, content, model, deleted_at) VALUES ('ins-2', 'test', 'model', datetime('now'))`,
      )
      .run();

    const result = reconcileInsights(db.raw);

    // The insight has has_embedding=1 but the memory_insights row is soft-deleted,
    // so it should be treated as missing → reset
    expect(result.resetEmbedding).toBe(1);
    expect(result.orphanedVector).toBe(0); // already deleted, no double-delete
  });

  it('calls log.info when changes are made', () => {
    const logged: Array<[string, Record<string, unknown> | undefined]> = [];
    const log = {
      info: (message: string, data?: Record<string, unknown>) =>
        logged.push([message, data]),
    };

    db.raw
      .prepare(
        `INSERT INTO insights (id, content, has_embedding) VALUES ('log-1', 'test', 1)`,
      )
      .run();

    reconcileInsights(db.raw, log);

    expect(logged).toHaveLength(1);
    expect(logged[0][0]).toBe('Insight reconciliation');
    expect(logged[0][1]).toEqual({ resetEmbedding: 1, orphanedVector: 0 });
  });

  it('does not log when no changes are made', () => {
    const logged: Array<[string, Record<string, unknown> | undefined]> = [];
    const log = {
      info: (message: string, data?: Record<string, unknown>) =>
        logged.push([message, data]),
    };

    reconcileInsights(db.raw, log);

    expect(logged).toHaveLength(0);
  });

  it('works through the Database facade', () => {
    db.raw
      .prepare(
        `INSERT INTO insights (id, content, has_embedding) VALUES ('facade-1', 'test', 1)`,
      )
      .run();
    db.raw
      .prepare(
        `INSERT INTO memory_insights (id, content, model) VALUES ('orphan-f', 'orphan', 'model')`,
      )
      .run();

    const result = db.reconcileInsights();

    expect(result.resetEmbedding).toBe(1);
    expect(result.orphanedVector).toBe(1);
  });
});
