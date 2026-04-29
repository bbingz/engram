import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { Database } from '../../src/core/db.js';

describe('migration_log', () => {
  let db: Database;
  let tmp: string;

  beforeEach(() => {
    tmp = mkdtempSync(join(tmpdir(), 'engram-mig-log-'));
    db = new Database(join(tmp, 'test.sqlite'));
  });

  afterEach(() => {
    db.close();
    rmSync(tmp, { recursive: true });
  });

  const basicInput = (id: string, old: string, next: string) => ({
    id,
    oldPath: old,
    newPath: next,
    oldBasename: old.split('/').pop() ?? '',
    newBasename: next.split('/').pop() ?? '',
  });

  it('three-phase happy path: fs_pending → fs_done → committed', () => {
    db.startMigration(basicInput('m1', '/a/foo', '/a/bar'));
    let row = db.findMigration('m1');
    expect(row?.state).toBe('fs_pending');
    expect(row?.finishedAt).toBeNull();

    db.markMigrationFsDone({
      id: 'm1',
      filesPatched: 3,
      occurrences: 12,
      ccDirRenamed: true,
      detail: { byte_diff: 42 },
    });
    row = db.findMigration('m1');
    expect(row?.state).toBe('fs_done');
    expect(row?.filesPatched).toBe(3);
    expect(row?.occurrences).toBe(12);
    expect(row?.ccDirRenamed).toBe(true);
    expect(row?.detail).toEqual({ byte_diff: 42 });
    expect(row?.finishedAt).toBeNull();

    db.finishMigration({ id: 'm1', sessionsUpdated: 7, aliasCreated: true });
    row = db.findMigration('m1');
    expect(row?.state).toBe('committed');
    expect(row?.sessionsUpdated).toBe(7);
    expect(row?.aliasCreated).toBe(true);
    expect(row?.finishedAt).not.toBeNull();
  });

  it('fail writes state=failed and error message', () => {
    db.startMigration(basicInput('m2', '/a/foo', '/a/bar'));
    db.failMigration('m2', 'EACCES on rename');
    const row = db.findMigration('m2');
    expect(row?.state).toBe('failed');
    expect(row?.error).toBe('EACCES on rename');
    expect(row?.finishedAt).not.toBeNull();
  });

  describe('state-machine preconditions', () => {
    it('markFsDone on non-existent id throws', () => {
      expect(() =>
        db.markMigrationFsDone({
          id: 'nope',
          filesPatched: 0,
          occurrences: 0,
          ccDirRenamed: false,
        }),
      ).toThrow(/migration nope/i);
    });

    it('markFsDone on a committed migration throws (no overwrite)', () => {
      db.startMigration(basicInput('m1', '/a', '/b'));
      db.markMigrationFsDone({
        id: 'm1',
        filesPatched: 1,
        occurrences: 1,
        ccDirRenamed: false,
      });
      db.finishMigration({ id: 'm1', sessionsUpdated: 1, aliasCreated: false });
      expect(() =>
        db.markMigrationFsDone({
          id: 'm1',
          filesPatched: 0,
          occurrences: 0,
          ccDirRenamed: false,
        }),
      ).toThrow(/state/i);
    });

    it('finishMigration on a fs_pending row throws (must be fs_done)', () => {
      db.startMigration(basicInput('m1', '/a', '/b'));
      expect(() =>
        db.finishMigration({
          id: 'm1',
          sessionsUpdated: 0,
          aliasCreated: false,
        }),
      ).toThrow(/state/i);
    });

    it('finishMigration on already-committed row throws (idempotent via early-exit elsewhere)', () => {
      db.startMigration(basicInput('m1', '/a', '/b'));
      db.markMigrationFsDone({
        id: 'm1',
        filesPatched: 0,
        occurrences: 0,
        ccDirRenamed: false,
      });
      db.finishMigration({ id: 'm1', sessionsUpdated: 5, aliasCreated: false });
      expect(() =>
        db.finishMigration({
          id: 'm1',
          sessionsUpdated: 0,
          aliasCreated: false,
        }),
      ).toThrow(/state/i);
    });

    it('failMigration on already-committed row throws', () => {
      db.startMigration(basicInput('m1', '/a', '/b'));
      db.markMigrationFsDone({
        id: 'm1',
        filesPatched: 0,
        occurrences: 0,
        ccDirRenamed: false,
      });
      db.finishMigration({ id: 'm1', sessionsUpdated: 0, aliasCreated: false });
      expect(() => db.failMigration('m1', 'oops')).toThrow(/state/i);
    });

    it('startMigration rejects old_path === new_path', () => {
      expect(() =>
        db.startMigration(basicInput('m-bad', '/foo/bar', '/foo/bar')),
      ).toThrow(/same/i);
    });

    it('failMigration is allowed from any non-terminal state', () => {
      db.startMigration(basicInput('m1', '/a', '/b'));
      db.failMigration('m1', 'fs error');
      expect(db.findMigration('m1')?.state).toBe('failed');

      db.startMigration(basicInput('m2', '/c', '/d'));
      db.markMigrationFsDone({
        id: 'm2',
        filesPatched: 0,
        occurrences: 0,
        ccDirRenamed: false,
      });
      db.failMigration('m2', 'db error');
      expect(db.findMigration('m2')?.state).toBe('failed');
    });
  });

  it('listMigrations orders newest-first and filters by state', () => {
    db.startMigration(basicInput('m-a', '/a', '/aa'));
    db.markMigrationFsDone({
      id: 'm-a',
      filesPatched: 0,
      occurrences: 0,
      ccDirRenamed: false,
    });
    db.finishMigration({ id: 'm-a', sessionsUpdated: 1, aliasCreated: false });
    db.startMigration(basicInput('m-b', '/b', '/bb'));
    db.failMigration('m-b', 'boom');
    db.startMigration(basicInput('m-c', '/c', '/cc'));

    const all = db.listMigrations();
    expect(all.map((m) => m.id)).toEqual(['m-c', 'm-b', 'm-a']);

    const committed = db.listMigrations({ state: 'committed' });
    expect(committed.map((m) => m.id)).toEqual(['m-a']);

    const failedOrPending = db.listMigrations({
      state: ['failed', 'fs_pending'],
    });
    expect(failedOrPending.map((m) => m.id).sort()).toEqual(['m-b', 'm-c']);
  });

  describe('hasPendingMigrationFor', () => {
    it('false when no migration covers path', () => {
      expect(db.hasPendingMigrationFor('/Users/example/foo.jsonl')).toBe(false);
    });

    it('true while state = fs_pending and path is under old_path', () => {
      db.startMigration(
        basicInput(
          'm1',
          '/Users/example/-Code-/old',
          '/Users/example/-Code-/new',
        ),
      );
      expect(
        db.hasPendingMigrationFor('/Users/example/-Code-/old/some/file.jsonl'),
      ).toBe(true);
    });

    it('true while state = fs_pending and path is under new_path', () => {
      db.startMigration(
        basicInput(
          'm1',
          '/Users/example/-Code-/old',
          '/Users/example/-Code-/new',
        ),
      );
      expect(
        db.hasPendingMigrationFor('/Users/example/-Code-/new/some/file.jsonl'),
      ).toBe(true);
    });

    it('true for exact old_path match', () => {
      db.startMigration(
        basicInput(
          'm1',
          '/Users/example/-Code-/old',
          '/Users/example/-Code-/new',
        ),
      );
      expect(db.hasPendingMigrationFor('/Users/example/-Code-/old')).toBe(true);
    });

    it('false after state transitions to committed', () => {
      db.startMigration(
        basicInput(
          'm1',
          '/Users/example/-Code-/old',
          '/Users/example/-Code-/new',
        ),
      );
      db.markMigrationFsDone({
        id: 'm1',
        filesPatched: 0,
        occurrences: 0,
        ccDirRenamed: false,
      });
      db.finishMigration({ id: 'm1', sessionsUpdated: 0, aliasCreated: false });
      expect(
        db.hasPendingMigrationFor('/Users/example/-Code-/old/some/file.jsonl'),
      ).toBe(false);
    });

    it('false after state transitions to failed', () => {
      db.startMigration(
        basicInput(
          'm1',
          '/Users/example/-Code-/old',
          '/Users/example/-Code-/new',
        ),
      );
      db.failMigration('m1', 'boom');
      expect(
        db.hasPendingMigrationFor('/Users/example/-Code-/old/some/file.jsonl'),
      ).toBe(false);
    });

    it('no prefix collision: /foo/bar does not cover /foo/bar-baz', () => {
      db.startMigration(basicInput('m1', '/foo/bar', '/foo/newbar'));
      expect(db.hasPendingMigrationFor('/foo/bar-baz/x.jsonl')).toBe(false);
      expect(db.hasPendingMigrationFor('/foo/barbar/x.jsonl')).toBe(false);
      // but /foo/bar/x still covered
      expect(db.hasPendingMigrationFor('/foo/bar/x.jsonl')).toBe(true);
    });

    it('LIKE wildcards in old_path (_ and %) do not cause false positives', () => {
      // path with underscore — must be matched literally, NOT as LIKE "_"
      db.startMigration(
        basicInput('m1', '/Users/john_doe/proj', '/Users/john_doe/newproj'),
      );
      // different literal char where the underscore is — must NOT be pending
      expect(db.hasPendingMigrationFor('/Users/johnXdoe/proj/x.jsonl')).toBe(
        false,
      );
      // correct path (exact underscore) — must BE pending
      expect(db.hasPendingMigrationFor('/Users/john_doe/proj/x.jsonl')).toBe(
        true,
      );
    });

    it('fs_done state also counts as pending (DB not yet committed)', () => {
      db.startMigration(basicInput('m1', '/foo/old', '/foo/new'));
      db.markMigrationFsDone({
        id: 'm1',
        filesPatched: 0,
        occurrences: 0,
        ccDirRenamed: false,
      });
      expect(db.hasPendingMigrationFor('/foo/old/x.jsonl')).toBe(true);
      expect(db.hasPendingMigrationFor('/foo/new/x.jsonl')).toBe(true);
    });

    it('stale pending (started > 1h ago) does NOT guard — watcher resumes', () => {
      // Codex #3 / Gemini #1: crashed migrations stuck in fs_pending
      // must not lock the watcher forever. TTL of 1 hour.
      db.startMigration(basicInput('m1', '/foo/old', '/foo/new'));
      // backdate the row to 2 hours ago
      db.raw
        .prepare(
          "UPDATE migration_log SET started_at = datetime('now', '-2 hours') WHERE id = ?",
        )
        .run('m1');
      expect(db.hasPendingMigrationFor('/foo/old/x.jsonl')).toBe(false);
    });
  });

  describe('cleanupStaleMigrations', () => {
    it('marks migrations older than 24h that are still non-terminal as failed', () => {
      db.startMigration(basicInput('m-old-pending', '/a', '/aa'));
      db.raw
        .prepare(
          "UPDATE migration_log SET started_at = datetime('now', '-2 days') WHERE id = ?",
        )
        .run('m-old-pending');

      db.startMigration(basicInput('m-old-fsdone', '/b', '/bb'));
      db.markMigrationFsDone({
        id: 'm-old-fsdone',
        filesPatched: 0,
        occurrences: 0,
        ccDirRenamed: false,
      });
      db.raw
        .prepare(
          "UPDATE migration_log SET started_at = datetime('now', '-2 days') WHERE id = ?",
        )
        .run('m-old-fsdone');

      db.startMigration(basicInput('m-new', '/c', '/cc')); // fresh, untouched

      const n = db.cleanupStaleMigrations();
      expect(n).toBe(2);
      expect(db.findMigration('m-old-pending')?.state).toBe('failed');
      expect(db.findMigration('m-old-pending')?.error).toMatch(/stale/i);
      expect(db.findMigration('m-old-fsdone')?.state).toBe('failed');
      expect(db.findMigration('m-new')?.state).toBe('fs_pending');
    });

    it('does not touch committed or already-failed rows', () => {
      db.startMigration(basicInput('m1', '/a', '/aa'));
      db.markMigrationFsDone({
        id: 'm1',
        filesPatched: 0,
        occurrences: 0,
        ccDirRenamed: false,
      });
      db.finishMigration({ id: 'm1', sessionsUpdated: 0, aliasCreated: false });
      db.raw
        .prepare(
          "UPDATE migration_log SET started_at = datetime('now', '-2 days') WHERE id = ?",
        )
        .run('m1');

      db.startMigration(basicInput('m2', '/b', '/bb'));
      db.failMigration('m2', 'prior error');
      db.raw
        .prepare(
          "UPDATE migration_log SET started_at = datetime('now', '-2 days') WHERE id = ?",
        )
        .run('m2');

      const n = db.cleanupStaleMigrations();
      expect(n).toBe(0);
      expect(db.findMigration('m1')?.state).toBe('committed');
      expect(db.findMigration('m2')?.state).toBe('failed');
      expect(db.findMigration('m2')?.error).toBe('prior error');
    });
  });
});
