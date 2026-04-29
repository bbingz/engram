import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  rmSync,
  writeFileSync,
} from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { Database } from '../../../src/core/db.js';
import { encodeCC } from '../../../src/core/project-move/encode-cc.js';
import { runProjectMove } from '../../../src/core/project-move/orchestrator.js';
import { diagnoseStuckMigrations } from '../../../src/core/project-move/recover.js';
import {
  UndoNotAllowedError,
  UndoStaleError,
  undoMigration,
} from '../../../src/core/project-move/undo.js';

describe('undoMigration', () => {
  let tmp: string;
  let home: string;
  let db: Database;
  let src: string;
  let dst: string;

  beforeEach(() => {
    tmp = mkdtempSync(join(tmpdir(), 'engram-undo-'));
    home = join(tmp, 'home');
    mkdirSync(home);
    for (const d of [
      '.claude/projects',
      '.codex/sessions',
      '.gemini/tmp',
      '.local/share/opencode',
      '.antigravity',
      '.copilot',
    ]) {
      mkdirSync(join(home, d), { recursive: true });
    }
    db = new Database(join(tmp, 'engram.sqlite'));

    src = join(tmp, 'projects', 'orig');
    dst = join(tmp, 'projects', 'renamed');
    mkdirSync(src, { recursive: true });
    writeFileSync(join(src, 'file.txt'), 'contents');

    const ccOld = join(home, '.claude', 'projects', encodeCC(src));
    mkdirSync(ccOld);
    writeFileSync(
      join(ccOld, 'session.jsonl'),
      `{"cwd":"${src}","text":"at ${src}"}\n`,
    );
  });

  afterEach(() => {
    db.close();
    rmSync(tmp, { recursive: true, force: true });
  });

  it('undoing a committed migration reverses FS + DB + alias', async () => {
    const forward = await runProjectMove(db, { src, dst, home });
    expect(forward.state).toBe('committed');
    expect(existsSync(dst)).toBe(true);
    expect(existsSync(src)).toBe(false);

    const undone = await undoMigration(db, forward.migrationId, { home });
    expect(undone.state).toBe('committed');
    expect(existsSync(src)).toBe(true);
    expect(existsSync(dst)).toBe(false);

    const undoLog = db.findMigration(undone.migrationId);
    expect(undoLog?.rolledBackOf).toBe(forward.migrationId);

    // Alias should be preserved AND a reverse alias added (renamed → orig)
    const aliases = db.listProjectAliases();
    expect(aliases).toContainEqual({ alias: 'orig', canonical: 'renamed' });
    expect(aliases).toContainEqual({ alias: 'renamed', canonical: 'orig' });
  });

  it('refuses to undo a failed migration (must run recover)', async () => {
    // Seed a failed migration directly
    db.startMigration({
      id: 'm-failed',
      oldPath: '/a',
      newPath: '/b',
      oldBasename: 'a',
      newBasename: 'b',
    });
    db.failMigration('m-failed', 'synthetic error');

    await expect(undoMigration(db, 'm-failed', { home })).rejects.toThrow(
      UndoNotAllowedError,
    );
  });

  it('refuses to undo a fs_pending migration', async () => {
    db.startMigration({
      id: 'm-pending',
      oldPath: '/a',
      newPath: '/b',
      oldBasename: 'a',
      newBasename: 'b',
    });
    await expect(undoMigration(db, 'm-pending', { home })).rejects.toThrow(
      UndoNotAllowedError,
    );
  });

  it('errors on unknown migration id', async () => {
    await expect(undoMigration(db, 'does-not-exist', { home })).rejects.toThrow(
      /not found/,
    );
  });

  it('UndoStaleError when newPath no longer exists (later migration overlaid)', async () => {
    const forward = await runProjectMove(db, { src, dst, home });
    // Simulate a later migration stealing dst away
    const { rename } = await import('node:fs/promises');
    await rename(dst, join(tmp, 'projects', 'further'));
    await expect(
      undoMigration(db, forward.migrationId, { home }),
    ).rejects.toThrow(UndoStaleError);
  });
});

describe('diagnoseStuckMigrations', () => {
  let tmp: string;
  let db: Database;

  beforeEach(() => {
    tmp = mkdtempSync(join(tmpdir(), 'engram-recover-'));
    db = new Database(join(tmp, 'engram.sqlite'));
  });
  afterEach(() => {
    db.close();
    rmSync(tmp, { recursive: true, force: true });
  });

  it('skips committed migrations by default', async () => {
    db.startMigration({
      id: 'm1',
      oldPath: '/a',
      newPath: '/b',
      oldBasename: 'a',
      newBasename: 'b',
    });
    db.markMigrationFsDone({
      id: 'm1',
      filesPatched: 0,
      occurrences: 0,
      ccDirRenamed: false,
    });
    db.finishMigration({ id: 'm1', sessionsUpdated: 0, aliasCreated: false });

    const diag = await diagnoseStuckMigrations(db);
    expect(diag).toHaveLength(0);
  });

  it('reports fs_pending migrations with FS observations', async () => {
    const src = join(tmp, 'src');
    mkdirSync(src);
    db.startMigration({
      id: 'm-pending',
      oldPath: src,
      newPath: join(tmp, 'dst'),
      oldBasename: 'src',
      newBasename: 'dst',
    });

    const diag = await diagnoseStuckMigrations(db);
    expect(diag).toHaveLength(1);
    expect(diag[0].state).toBe('fs_pending');
    expect(diag[0].fs.oldPathExists).toBe(true);
    expect(diag[0].fs.newPathExists).toBe(false);
    expect(diag[0].recommendation).toMatch(/untouched|retry/i);
  });

  it('recommends commit-migration when fs_done but FS shows move succeeded', async () => {
    const src = join(tmp, 'gone');
    const dst = join(tmp, 'here');
    mkdirSync(dst); // dst exists, src doesn't
    db.startMigration({
      id: 'm-fsdone',
      oldPath: src,
      newPath: dst,
      oldBasename: 'gone',
      newBasename: 'here',
    });
    db.markMigrationFsDone({
      id: 'm-fsdone',
      filesPatched: 0,
      occurrences: 0,
      ccDirRenamed: false,
    });

    const diag = await diagnoseStuckMigrations(db);
    expect(diag).toHaveLength(1);
    expect(diag[0].state).toBe('fs_done');
    expect(diag[0].recommendation).toMatch(/commit-migration|DB commit/i);
  });
});
