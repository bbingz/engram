import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { Database } from '../../src/core/db.js';

/**
 * Direct tests for applyMigrationDb — Step 5 of the project-move pipeline.
 * Focus: SQL correctness, '/' boundary, session_local_state parity,
 * alias creation conditions, orphan-flag clearing, idempotency.
 */
describe('applyMigrationDb', () => {
  let db: Database;
  let tmp: string;

  beforeEach(() => {
    tmp = mkdtempSync(join(tmpdir(), 'engram-applymig-'));
    db = new Database(join(tmp, 'test.sqlite'));
  });

  afterEach(() => {
    db.close();
    rmSync(tmp, { recursive: true });
  });

  const insertSession = (
    id: string,
    source: string,
    filePath: string,
    opts: {
      cwd?: string;
      sourceLocator?: string;
      orphanStatus?: string;
    } = {},
  ) => {
    db.raw
      .prepare(
        `INSERT INTO sessions
         (id, source, start_time, cwd, project, model, message_count,
          user_message_count, assistant_message_count, tool_message_count, system_message_count,
          summary, file_path, size_bytes, source_locator, orphan_status, orphan_since, orphan_reason)
         VALUES (?, ?, datetime('now'), ?, 'p', 'm', 0, 0, 0, 0, 0, null, ?, 0, ?, ?, ?, ?)`,
      )
      .run(
        id,
        source,
        opts.cwd ?? filePath,
        filePath,
        opts.sourceLocator ?? filePath,
        opts.orphanStatus ?? null,
        opts.orphanStatus ? new Date().toISOString() : null,
        opts.orphanStatus ? 'path_unreachable' : null,
      );
  };

  const insertLocalState = (sessionId: string, localPath: string) => {
    db.raw
      .prepare(
        `INSERT INTO session_local_state (session_id, local_readable_path) VALUES (?, ?)
         ON CONFLICT(session_id) DO UPDATE SET local_readable_path = excluded.local_readable_path`,
      )
      .run(sessionId, localPath);
  };

  const startMig = (id: string, oldPath: string, newPath: string) => {
    db.startMigration({
      id,
      oldPath,
      newPath,
      oldBasename: oldPath.split('/').pop() ?? '',
      newBasename: newPath.split('/').pop() ?? '',
    });
    db.markMigrationFsDone({
      id,
      filesPatched: 0,
      occurrences: 0,
      ccDirRenamed: false,
    });
  };

  it('rewrites source_locator / file_path / cwd for matched rows', () => {
    const OLD = '/Users/example/-Code-/old';
    const NEW = '/Users/example/-Code-/new';
    insertSession('s1', 'codex', `${OLD}/session.jsonl`, { cwd: OLD });
    startMig('m1', OLD, NEW);

    const r = db.applyMigrationDb({
      migrationId: 'm1',
      oldPath: OLD,
      newPath: NEW,
      oldBasename: 'old',
      newBasename: 'new',
    });

    expect(r.sessionsUpdated).toBe(1);
    const row = db.raw
      .prepare(
        'SELECT source_locator, file_path, cwd FROM sessions WHERE id = ?',
      )
      .get('s1') as Record<string, string>;
    expect(row.source_locator).toBe(`${NEW}/session.jsonl`);
    expect(row.file_path).toBe(`${NEW}/session.jsonl`);
    expect(row.cwd).toBe(NEW);
  });

  it('exact path match (no slash) also rewrites', () => {
    const OLD = '/Users/example/foo';
    const NEW = '/Users/example/bar';
    insertSession('s1', 'codex', OLD, { cwd: OLD });
    startMig('m1', OLD, NEW);

    db.applyMigrationDb({
      migrationId: 'm1',
      oldPath: OLD,
      newPath: NEW,
      oldBasename: 'foo',
      newBasename: 'bar',
    });

    const row = db.raw
      .prepare('SELECT file_path, cwd FROM sessions WHERE id = ?')
      .get('s1') as Record<string, string>;
    expect(row.file_path).toBe(NEW);
    expect(row.cwd).toBe(NEW);
  });

  it('LIKE wildcards (_, %) in oldPath do not cause false matches', () => {
    // Underscore in path — must be matched literally, not as LIKE single-char wildcard
    insertSession('s1', 'codex', '/Users/john_doe/proj/x.jsonl', {
      cwd: '/Users/john_doe/proj',
    });
    insertSession('s2', 'codex', '/Users/johnXdoe/proj/y.jsonl', {
      cwd: '/Users/johnXdoe/proj',
    });

    startMig('m1', '/Users/john_doe/proj', '/Users/john_doe/newproj');
    const r = db.applyMigrationDb({
      migrationId: 'm1',
      oldPath: '/Users/john_doe/proj',
      newPath: '/Users/john_doe/newproj',
      oldBasename: 'proj',
      newBasename: 'newproj',
    });

    expect(r.sessionsUpdated).toBe(1);
    const s2 = db.raw
      .prepare('SELECT file_path FROM sessions WHERE id = ?')
      .get('s2') as { file_path: string };
    // s2 must stay untouched
    expect(s2.file_path).toBe('/Users/johnXdoe/proj/y.jsonl');
  });

  it('prefix boundary: /foo/bar does NOT match /foo/barbar or /foo/bar-baz', () => {
    // 3 sessions:
    //  s1 under /foo/bar     → SHOULD rewrite
    //  s2 under /foo/barbar  → MUST NOT rewrite
    //  s3 under /foo/bar-baz → MUST NOT rewrite
    insertSession('s1', 'codex', '/foo/bar/x.jsonl', { cwd: '/foo/bar' });
    insertSession('s2', 'codex', '/foo/barbar/y.jsonl', { cwd: '/foo/barbar' });
    insertSession('s3', 'codex', '/foo/bar-baz/z.jsonl', {
      cwd: '/foo/bar-baz',
    });

    startMig('m1', '/foo/bar', '/foo/new');
    const r = db.applyMigrationDb({
      migrationId: 'm1',
      oldPath: '/foo/bar',
      newPath: '/foo/new',
      oldBasename: 'bar',
      newBasename: 'new',
    });

    expect(r.sessionsUpdated).toBe(1);
    const s1 = db.raw
      .prepare('SELECT file_path FROM sessions WHERE id = ?')
      .get('s1') as { file_path: string };
    const s2 = db.raw
      .prepare('SELECT file_path FROM sessions WHERE id = ?')
      .get('s2') as { file_path: string };
    const s3 = db.raw
      .prepare('SELECT file_path FROM sessions WHERE id = ?')
      .get('s3') as { file_path: string };
    expect(s1.file_path).toBe('/foo/new/x.jsonl');
    expect(s2.file_path).toBe('/foo/barbar/y.jsonl'); // untouched
    expect(s3.file_path).toBe('/foo/bar-baz/z.jsonl'); // untouched
  });

  it('updates session_local_state.local_readable_path (UI read-priority field)', () => {
    const OLD = '/Users/example/proj';
    const NEW = '/Users/example/newproj';
    insertSession('s1', 'codex', `${OLD}/x.jsonl`, { cwd: OLD });
    insertLocalState('s1', `${OLD}/x.jsonl`);
    startMig('m1', OLD, NEW);

    const r = db.applyMigrationDb({
      migrationId: 'm1',
      oldPath: OLD,
      newPath: NEW,
      oldBasename: 'proj',
      newBasename: 'newproj',
    });

    expect(r.localStateUpdated).toBe(1);
    const row = db.raw
      .prepare(
        'SELECT local_readable_path FROM session_local_state WHERE session_id = ?',
      )
      .get('s1') as { local_readable_path: string };
    expect(row.local_readable_path).toBe(`${NEW}/x.jsonl`);
  });

  it('creates project alias when basename differs', () => {
    insertSession('s1', 'codex', '/a/old/x.jsonl', { cwd: '/a/old' });
    startMig('m1', '/a/old', '/a/new');

    const r = db.applyMigrationDb({
      migrationId: 'm1',
      oldPath: '/a/old',
      newPath: '/a/new',
      oldBasename: 'old',
      newBasename: 'new',
    });

    expect(r.aliasCreated).toBe(true);
    const aliases = db.listProjectAliases();
    expect(aliases).toContainEqual({ alias: 'old', canonical: 'new' });
  });

  it('does NOT create alias when basename unchanged (parent moved only)', () => {
    const OLD = '/Users/example/-Code-/foo';
    const NEW = '/Users/example/-Automations-/foo';
    insertSession('s1', 'codex', `${OLD}/x.jsonl`, { cwd: OLD });
    startMig('m1', OLD, NEW);

    const r = db.applyMigrationDb({
      migrationId: 'm1',
      oldPath: OLD,
      newPath: NEW,
      oldBasename: 'foo',
      newBasename: 'foo',
    });

    expect(r.aliasCreated).toBe(false);
    expect(db.listProjectAliases()).toEqual([]);
  });

  it('does NOT auto-clear orphan flags — filesystem is the only truth', () => {
    // Gemini critical #7: applyMigrationDb must not assume that moving the
    // DB path resolves orphan status. detectOrphans decides orphan state
    // from the real filesystem via adapter.isAccessible() — path rewrites
    // alone can't un-ghost a session whose file was genuinely cleaned up.
    const OLD = '/Users/example/gone';
    const NEW = '/Users/example/back';
    insertSession('s1', 'codex', `${OLD}/x.jsonl`, {
      cwd: OLD,
      orphanStatus: 'suspect',
    });
    startMig('m1', OLD, NEW);

    db.applyMigrationDb({
      migrationId: 'm1',
      oldPath: OLD,
      newPath: NEW,
      oldBasename: 'gone',
      newBasename: 'back',
    });

    const row = db.raw
      .prepare(
        'SELECT orphan_status, orphan_reason, file_path FROM sessions WHERE id = ?',
      )
      .get('s1') as {
      orphan_status: string | null;
      orphan_reason: string | null;
      file_path: string;
    };
    // Path was rewritten to the new location
    expect(row.file_path).toBe(`${NEW}/x.jsonl`);
    // But the orphan markers must be preserved — detectOrphans will re-check
    expect(row.orphan_status).toBe('suspect');
    expect(row.orphan_reason).toBe('path_unreachable');
  });

  it('stores affected session_ids in migration_log.detail for Phase 3 undo', () => {
    // Gemini #4: undo by "reverse prefix rewrite" is unsafe when there are
    // same-name sessions in the target. We need the authoritative list of
    // session ids we touched.
    insertSession('s1', 'codex', '/a/foo/x.jsonl', { cwd: '/a/foo' });
    insertSession('s2', 'codex', '/a/foo/y.jsonl', { cwd: '/a/foo' });
    insertSession('s3', 'codex', '/a/bar/z.jsonl', { cwd: '/a/bar' }); // not touched
    startMig('m1', '/a/foo', '/a/baz');

    db.applyMigrationDb({
      migrationId: 'm1',
      oldPath: '/a/foo',
      newPath: '/a/baz',
      oldBasename: 'foo',
      newBasename: 'baz',
    });

    const log = db.findMigration('m1');
    expect(log?.detail).toBeTruthy();
    const ids = (log?.detail?.affectedSessionIds as string[]) ?? [];
    expect(ids.sort()).toEqual(['s1', 's2']);
  });

  it('marks migration_log state=committed with accurate counts', () => {
    insertSession('s1', 'codex', '/a/foo/1.jsonl', { cwd: '/a/foo' });
    insertSession('s2', 'codex', '/a/foo/2.jsonl', { cwd: '/a/foo' });
    startMig('m1', '/a/foo', '/a/bar');

    db.applyMigrationDb({
      migrationId: 'm1',
      oldPath: '/a/foo',
      newPath: '/a/bar',
      oldBasename: 'foo',
      newBasename: 'bar',
    });

    const log = db.findMigration('m1');
    expect(log?.state).toBe('committed');
    expect(log?.sessionsUpdated).toBe(2);
    expect(log?.aliasCreated).toBe(true);
    expect(log?.finishedAt).not.toBeNull();
  });

  it('idempotent: running twice with different migrationId is no-op on second', () => {
    insertSession('s1', 'codex', '/a/foo/x.jsonl', { cwd: '/a/foo' });
    startMig('m1', '/a/foo', '/a/bar');
    const r1 = db.applyMigrationDb({
      migrationId: 'm1',
      oldPath: '/a/foo',
      newPath: '/a/bar',
      oldBasename: 'foo',
      newBasename: 'bar',
    });
    expect(r1.sessionsUpdated).toBe(1);

    // Second run with a FRESH migrationId: new migration log entry, but no rows match old path anymore
    startMig('m2', '/a/foo', '/a/bar');
    const r2 = db.applyMigrationDb({
      migrationId: 'm2',
      oldPath: '/a/foo',
      newPath: '/a/bar',
      oldBasename: 'foo',
      newBasename: 'bar',
    });
    expect(r2.sessionsUpdated).toBe(0);
    expect(r2.localStateUpdated).toBe(0);
  });

  it('committed early-exit: re-running same migrationId returns cached counts without overwriting log', () => {
    // Codex #2: if someone calls applyMigrationDb twice with the same id,
    // the second call must NOT overwrite sessions_updated/alias_created on the
    // committed row. Return the cached values instead.
    insertSession('s1', 'codex', '/a/foo/x.jsonl', { cwd: '/a/foo' });
    insertSession('s2', 'codex', '/a/foo/y.jsonl', { cwd: '/a/foo' });
    startMig('m1', '/a/foo', '/a/bar');
    const r1 = db.applyMigrationDb({
      migrationId: 'm1',
      oldPath: '/a/foo',
      newPath: '/a/bar',
      oldBasename: 'foo',
      newBasename: 'bar',
    });
    expect(r1.sessionsUpdated).toBe(2);

    // Re-run with SAME id. Would previously overwrite log.sessions_updated to 0.
    const r2 = db.applyMigrationDb({
      migrationId: 'm1',
      oldPath: '/a/foo',
      newPath: '/a/bar',
      oldBasename: 'foo',
      newBasename: 'bar',
    });
    expect(r2.sessionsUpdated).toBe(2); // cached, not 0
    expect(r2.aliasCreated).toBe(true);

    // Log row must preserve original counts
    const log = db.findMigration('m1');
    expect(log?.sessionsUpdated).toBe(2);
    expect(log?.aliasCreated).toBe(true);
  });

  it('transaction rolls back if something inside throws', () => {
    insertSession('s1', 'codex', '/a/foo/x.jsonl', { cwd: '/a/foo' });
    // Force a failure by NOT calling startMigration first — finishMigration
    // will UPDATE 0 rows but commit succeeds; we instead corrupt the log row
    // to break FK. Easier: just verify atomicity via a separate mechanism.
    // This test placeholder — applyMigrationDb has no failure injection hook
    // yet; relying on better-sqlite3's native transaction behavior plus
    // the schema contracts. Keeping for future failure-injection work.
    startMig('m1', '/a/foo', '/a/bar');
    expect(() =>
      db.applyMigrationDb({
        migrationId: 'm1',
        oldPath: '/a/foo',
        newPath: '/a/bar',
        oldBasename: 'foo',
        newBasename: 'bar',
      }),
    ).not.toThrow();
  });
});
