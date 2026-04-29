import { mkdirSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import BetterSqlite3 from 'better-sqlite3';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { CursorAdapter } from '../../src/adapters/cursor.js';

const __dirname = dirname(fileURLToPath(import.meta.url));
const FIXTURE_DB = join(__dirname, '../fixtures/cursor/state.vscdb');

describe('CursorAdapter', () => {
  const adapter = new CursorAdapter(FIXTURE_DB);

  it('name is cursor', () => {
    expect(adapter.name).toBe('cursor');
  });

  it('listSessionFiles yields virtual paths', async () => {
    const files: string[] = [];
    for await (const f of adapter.listSessionFiles()) {
      files.push(f);
    }
    expect(files).toHaveLength(1);
    expect(files[0]).toContain('abc-123');
  });

  it('parseSessionInfo returns session metadata', async () => {
    const files: string[] = [];
    for await (const f of adapter.listSessionFiles()) files.push(f);
    const info = await adapter.parseSessionInfo(files[0]);
    expect(info).not.toBeNull();
    expect(info?.id).toBe('abc-123');
    expect(info?.source).toBe('cursor');
    expect(info?.summary).toBe('Fix the login bug');
  });

  it('streamMessages yields user then assistant', async () => {
    const files: string[] = [];
    for await (const f of adapter.listSessionFiles()) files.push(f);
    const msgs: { role: string; content: string }[] = [];
    for await (const m of adapter.streamMessages(files[0])) msgs.push(m);
    expect(msgs).toHaveLength(2);
    expect(msgs[0]).toMatchObject({
      role: 'user',
      content: 'Fix the login bug',
    });
    expect(msgs[1]).toMatchObject({
      role: 'assistant',
      content: 'I found the issue in auth.ts',
    });
  });

  describe('cwd inference from composer context', () => {
    const tmpDir = join(tmpdir(), `engram-cursor-cwd-${Date.now()}`);
    const dbPath = join(tmpDir, 'state.vscdb');

    beforeAll(() => {
      mkdirSync(tmpDir, { recursive: true });
      const db = new BetterSqlite3(dbPath);
      db.exec(`CREATE TABLE cursorDiskKV (key TEXT PRIMARY KEY, value TEXT)`);
      const folderComposer = {
        composerId: 'with-folder',
        createdAt: 1771392000000,
        lastUpdatedAt: 1771392005000,
        context: {
          folderSelections: [{ uri: { fsPath: '/Users/me/proj-root' } }],
        },
        conversation: [{ type: 1, text: 'hi' }],
      };
      const fileComposer = {
        composerId: 'with-file',
        createdAt: 1771392000000,
        lastUpdatedAt: 1771392005000,
        context: {
          fileSelections: [
            { uri: { fsPath: '/Users/me/proj-root/src/index.ts' } },
          ],
        },
        conversation: [{ type: 1, text: 'hi' }],
      };
      const emptyComposer = {
        composerId: 'empty-context',
        createdAt: 1771392000000,
        lastUpdatedAt: 1771392005000,
        conversation: [{ type: 1, text: 'hi' }],
      };
      const ins = db.prepare(
        'INSERT INTO cursorDiskKV (key, value) VALUES (?, ?)',
      );
      ins.run('composerData:with-folder', JSON.stringify(folderComposer));
      ins.run('composerData:with-file', JSON.stringify(fileComposer));
      ins.run('composerData:empty-context', JSON.stringify(emptyComposer));
      db.close();
    });

    afterAll(() => rmSync(tmpDir, { recursive: true, force: true }));

    it('uses folderSelections[0] when present', async () => {
      const a = new CursorAdapter(dbPath);
      const info = await a.parseSessionInfo(`${dbPath}?composer=with-folder`);
      expect(info?.cwd).toBe('/Users/me/proj-root');
    });

    it('falls back to dirname of fileSelections[0]', async () => {
      const a = new CursorAdapter(dbPath);
      const info = await a.parseSessionInfo(`${dbPath}?composer=with-file`);
      expect(info?.cwd).toBe('/Users/me/proj-root/src');
    });

    it('returns empty string when no context signal exists', async () => {
      const a = new CursorAdapter(dbPath);
      const info = await a.parseSessionInfo(`${dbPath}?composer=empty-context`);
      expect(info?.cwd).toBe('');
    });
  });

  describe('cwd inference edge cases', () => {
    const tmpDir = join(tmpdir(), `engram-cursor-cwd-edges-${Date.now()}`);
    const dbPath = join(tmpDir, 'state.vscdb');

    beforeAll(() => {
      mkdirSync(tmpDir, { recursive: true });
      const db = new BetterSqlite3(dbPath);
      db.exec(`CREATE TABLE cursorDiskKV (key TEXT PRIMARY KEY, value TEXT)`);
      // First folderSelection has no fsPath; should fall through to file
      const folderEmpty = {
        composerId: 'folder-empty',
        createdAt: 1771392000000,
        lastUpdatedAt: 1771392005000,
        context: {
          folderSelections: [{ uri: {} }],
          fileSelections: [
            { uri: { fsPath: '/Users/me/proj-root/src/index.ts' } },
          ],
        },
        conversation: [{ type: 1, text: 'hi' }],
      };
      // Relative fsPath — adapter is best-effort; documents current behavior
      const relativeFile = {
        composerId: 'rel-file',
        createdAt: 1771392000000,
        lastUpdatedAt: 1771392005000,
        context: {
          fileSelections: [{ uri: { fsPath: 'src/index.ts' } }],
        },
        conversation: [{ type: 1, text: 'hi' }],
      };
      const ins = db.prepare(
        'INSERT INTO cursorDiskKV (key, value) VALUES (?, ?)',
      );
      ins.run('composerData:folder-empty', JSON.stringify(folderEmpty));
      ins.run('composerData:rel-file', JSON.stringify(relativeFile));
      db.close();
    });

    afterAll(() => rmSync(tmpDir, { recursive: true, force: true }));

    it('falls through to fileSelections when first folderSelection has no fsPath', async () => {
      const a = new CursorAdapter(dbPath);
      const info = await a.parseSessionInfo(`${dbPath}?composer=folder-empty`);
      expect(info?.cwd).toBe('/Users/me/proj-root/src');
    });

    it('passes relative fsPath through dirname() without resolving', async () => {
      const a = new CursorAdapter(dbPath);
      const info = await a.parseSessionInfo(`${dbPath}?composer=rel-file`);
      // dirname('src/index.ts') === 'src' — best-effort heuristic, not abs
      expect(info?.cwd).toBe('src');
    });
  });

  describe('cwd inference: more edge cases', () => {
    const tmpDir = join(tmpdir(), `engram-cursor-cwd-edge2-${Date.now()}`);
    const dbPath = join(tmpDir, 'state.vscdb');

    beforeAll(() => {
      mkdirSync(tmpDir, { recursive: true });
      const db = new BetterSqlite3(dbPath);
      db.exec(`CREATE TABLE cursorDiskKV (key TEXT PRIMARY KEY, value TEXT)`);

      // First folderSelection empty, second has fsPath. Adapter currently only
      // looks at [0] — documents that behavior so a future change is intentional.
      const secondFolderHasPath = {
        composerId: 'second-folder',
        createdAt: 1771392000000,
        lastUpdatedAt: 1771392005000,
        context: {
          folderSelections: [{ uri: {} }, { uri: { fsPath: '/Users/me/p2' } }],
          fileSelections: [{ uri: { fsPath: '/Users/me/file-fb/main.ts' } }],
        },
        conversation: [{ type: 1, text: 'hi' }],
      };

      // Symlink-style fsPath: adapter does not resolve; passes through verbatim.
      const symlinkFolder = {
        composerId: 'symlink',
        createdAt: 1771392000000,
        lastUpdatedAt: 1771392005000,
        context: {
          folderSelections: [
            { uri: { fsPath: '/Users/me/symlink-to-real-proj' } },
          ],
        },
        conversation: [{ type: 1, text: 'hi' }],
      };

      const ins = db.prepare(
        'INSERT INTO cursorDiskKV (key, value) VALUES (?, ?)',
      );
      ins.run(
        'composerData:second-folder',
        JSON.stringify(secondFolderHasPath),
      );
      ins.run('composerData:symlink', JSON.stringify(symlinkFolder));
      db.close();
    });

    afterAll(() => rmSync(tmpDir, { recursive: true, force: true }));

    it('does not scan past folderSelections[0] — falls through to fileSelections', async () => {
      const a = new CursorAdapter(dbPath);
      const info = await a.parseSessionInfo(`${dbPath}?composer=second-folder`);
      // [1].fsPath = /Users/me/p2 is ignored; falls through to file dirname
      expect(info?.cwd).toBe('/Users/me/file-fb');
    });

    it('returns symlink path verbatim without realpath resolution', async () => {
      const a = new CursorAdapter(dbPath);
      const info = await a.parseSessionInfo(`${dbPath}?composer=symlink`);
      expect(info?.cwd).toBe('/Users/me/symlink-to-real-proj');
    });
  });
});
