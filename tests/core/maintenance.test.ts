import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import {
  checkpointWal,
  detectOrphans,
  markOrphanByPath,
  reconcileInsights,
} from '../../src/core/db/maintenance.js';
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

describe('orphan detection', () => {
  let db: Database;
  let tmpDir: string;

  // Minimal fake adapter backed by a presence set we control per test.
  function makeAdapter(name: string, present: Set<string>) {
    return {
      name,
      isAccessible: (loc: string) => Promise.resolve(present.has(loc)),
    };
  }

  const insertSession = (
    db: Database,
    id: string,
    source: string,
    locator: string,
  ) => {
    db.raw
      .prepare(
        `INSERT INTO sessions
         (id, source, start_time, cwd, project, model, message_count,
          user_message_count, assistant_message_count, tool_message_count, system_message_count,
          summary, file_path, size_bytes, source_locator)
         VALUES (?, ?, datetime('now'), '/c', 'p', 'm', 0, 0, 0, 0, 0, null, ?, 0, ?)`,
      )
      .run(id, source, locator, locator);
  };

  beforeEach(() => {
    tmpDir = mkdtempSync(join(tmpdir(), 'engram-orphan-test-'));
    db = new Database(join(tmpDir, 'test.sqlite'));
  });

  afterEach(() => {
    db.close();
    rmSync(tmpDir, { recursive: true });
  });

  it('marks unreachable session as suspect on first scan', async () => {
    const existing = join(tmpDir, 'present.jsonl');
    writeFileSync(existing, 'x');
    insertSession(db, 's-ok', 'codex', existing);
    insertSession(db, 's-missing', 'codex', join(tmpDir, 'gone.jsonl'));

    const present = new Set([existing]);
    const r = await detectOrphans(db.raw, [makeAdapter('codex', present)]);

    expect(r.newlyFlagged).toBe(1);
    const row = db.raw
      .prepare('SELECT orphan_status, orphan_reason FROM sessions WHERE id = ?')
      .get('s-missing') as { orphan_status: string; orphan_reason: string };
    expect(row.orphan_status).toBe('suspect');
    expect(row.orphan_reason).toBe('path_unreachable');
  });

  it('clears orphan state when file returns (rename / mount recovery)', async () => {
    const p = join(tmpDir, 'once-gone.jsonl');
    insertSession(db, 's1', 'codex', p);
    db.raw
      .prepare(
        `UPDATE sessions SET orphan_status='suspect', orphan_since=datetime('now','-1 days'), orphan_reason='path_unreachable' WHERE id = ?`,
      )
      .run('s1');
    writeFileSync(p, 'x');

    const r = await detectOrphans(db.raw, [makeAdapter('codex', new Set([p]))]);

    expect(r.recovered).toBe(1);
    const row = db.raw
      .prepare(
        'SELECT orphan_status, orphan_since, orphan_reason FROM sessions WHERE id = ?',
      )
      .get('s1') as {
      orphan_status: string | null;
      orphan_since: string | null;
      orphan_reason: string | null;
    };
    expect(row.orphan_status).toBeNull();
    expect(row.orphan_since).toBeNull();
    expect(row.orphan_reason).toBeNull();
  });

  it('promotes suspect to confirmed after grace period', async () => {
    insertSession(db, 's-old', 'codex', join(tmpDir, 'nope.jsonl'));
    db.raw
      .prepare(
        `UPDATE sessions SET orphan_status='suspect', orphan_since=datetime('now','-40 days'), orphan_reason='path_unreachable' WHERE id = ?`,
      )
      .run('s-old');

    const r = await detectOrphans(db.raw, [makeAdapter('codex', new Set())]);

    expect(r.confirmed).toBe(1);
    const row = db.raw
      .prepare('SELECT orphan_status FROM sessions WHERE id = ?')
      .get('s-old') as { orphan_status: string };
    expect(row.orphan_status).toBe('confirmed');
  });

  it('skips sync:// locators', async () => {
    insertSession(db, 's-sync', 'codex', 'sync://peer/abc');
    const r = await detectOrphans(db.raw, [makeAdapter('codex', new Set())]);
    expect(r.skipped).toBe(1);
    expect(r.newlyFlagged).toBe(0);
  });

  it('markOrphanByPath flags rows whose locator matches', () => {
    const p = join(tmpDir, 'x.jsonl');
    insertSession(db, 's-p', 'codex', p);

    const touched = markOrphanByPath(db.raw, p, 'cleaned_by_source');

    expect(touched).toBe(1);
    const row = db.raw
      .prepare('SELECT orphan_status, orphan_reason FROM sessions WHERE id = ?')
      .get('s-p') as { orphan_status: string; orphan_reason: string };
    expect(row.orphan_status).toBe('suspect');
    expect(row.orphan_reason).toBe('cleaned_by_source');
  });

  it('markOrphanByPath is idempotent (preserves first reason)', () => {
    const p = join(tmpDir, 'y.jsonl');
    insertSession(db, 's-y', 'codex', p);
    markOrphanByPath(db.raw, p, 'cleaned_by_source');
    const touched2 = markOrphanByPath(db.raw, p, 'file_deleted');
    // Second call still hits the row but COALESCE keeps the first reason.
    expect(touched2).toBe(1);
    const row = db.raw
      .prepare('SELECT orphan_reason FROM sessions WHERE id = ?')
      .get('s-y') as { orphan_reason: string };
    expect(row.orphan_reason).toBe('cleaned_by_source');
  });
});

describe('checkpointWal', () => {
  let db: Database;
  let tmpDir: string;

  beforeEach(() => {
    tmpDir = mkdtempSync(join(tmpdir(), 'engram-checkpoint-test-'));
    db = new Database(join(tmpDir, 'test.sqlite'));
  });

  afterEach(() => {
    db.close();
    rmSync(tmpDir, { recursive: true });
  });

  it('returns busy/log/checkpointed on a fresh DB', () => {
    const r = checkpointWal(db.raw, 'TRUNCATE');
    expect(r.busy).toBeTypeOf('number');
    expect(r.log).toBeTypeOf('number');
    expect(r.checkpointed).toBeTypeOf('number');
    expect(r.busy).toBe(0);
  });

  it('truncates WAL after writes when no other reader blocks', () => {
    // Force WAL growth with a few writes.
    db.raw.exec(
      "INSERT INTO insights (id, content) VALUES ('c-1', 'one'), ('c-2', 'two'), ('c-3', 'three')",
    );
    const r = checkpointWal(db.raw, 'TRUNCATE');
    expect(r.busy).toBe(0);
    // All pending frames moved into the main DB file.
    expect(r.checkpointed).toBe(r.log);
  });

  it('honors PASSIVE mode without throwing', () => {
    const r = checkpointWal(db.raw, 'PASSIVE');
    expect(r.busy).toBe(0);
  });
});
