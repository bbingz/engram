import { mkdirSync, rmSync, writeFileSync } from 'node:fs';
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

  it('parseSessionInfo keeps first user text as summary only (repro)', async () => {
    const files: string[] = [];
    for await (const f of adapter.listSessionFiles()) files.push(f);
    const info = await adapter.parseSessionInfo(files[0]);
    expect(info).not.toBeNull();
    expect(info?.id).toBe('abc-123');
    expect(info?.source).toBe('cursor');
    expect(info?.summary).toBe('Fix the login bug');
    expect(info?.displayTitle).toBeUndefined();
  });

  it('unwraps nested Cursor conversation summaries (repro)', async () => {
    const tmpDir = join(tmpdir(), `engram-cursor-summary-${Date.now()}`);
    mkdirSync(tmpDir, { recursive: true });
    const dbPath = join(tmpDir, 'state.vscdb');
    const db = new BetterSqlite3(dbPath);
    db.exec('CREATE TABLE cursorDiskKV (key TEXT PRIMARY KEY, value TEXT)');
    db.prepare('INSERT INTO cursorDiskKV (key, value) VALUES (?, ?)').run(
      'composerData:nested',
      JSON.stringify({
        composerId: 'nested',
        createdAt: 1_700_000_000_000,
        lastUpdatedAt: 1_700_000_000_000,
        latestConversationSummary: {
          summary: { summary: 'Nested Cursor title' },
        },
        conversation: [{ type: 1, text: 'question' }],
      }),
    );
    db.close();
    try {
      const info = await new CursorAdapter(dbPath).parseSessionInfo(
        `${dbPath}?composer=nested`,
      );
      expect(info?.summary).toBe('Nested Cursor title');
    } finally {
      rmSync(tmpDir, { recursive: true, force: true });
    }
  });

  it('uses global migrated headers for unique cwd and official title (repro)', async () => {
    const tmpDir = join(tmpdir(), `engram-cursor-migrated-${Date.now()}`);
    const globalStorage = join(tmpDir, 'globalStorage');
    const workspaceStorage = join(tmpDir, 'workspaceStorage');
    const workspaceName = 'migrated-workspace';
    const dbPath = join(globalStorage, 'state.vscdb');
    mkdirSync(globalStorage, { recursive: true });
    mkdirSync(workspaceStorage, { recursive: true });
    const db = new BetterSqlite3(dbPath);
    db.exec(
      'CREATE TABLE cursorDiskKV (key TEXT PRIMARY KEY, value TEXT); CREATE TABLE ItemTable (key TEXT PRIMARY KEY, value TEXT)',
    );
    db.prepare('INSERT INTO cursorDiskKV (key, value) VALUES (?, ?)').run(
      'composerData:migrated',
      JSON.stringify({
        composerId: 'migrated',
        name: '  Official migrated Cursor title  ',
        createdAt: 1_700_000_000_000,
        lastUpdatedAt: 1_700_000_000_000,
        latestConversationSummary: {
          summary: { summary: 'Nested migrated digest' },
        },
        conversation: [{ type: 1, text: 'question' }],
      }),
    );
    db.prepare('INSERT INTO ItemTable (key, value) VALUES (?, ?)').run(
      'composer.composerHeaders',
      JSON.stringify({
        allComposers: [
          {
            composerId: 'migrated',
            workspaceIdentifier: { id: workspaceName },
          },
        ],
      }),
    );
    db.close();
    const workspace = join(workspaceStorage, workspaceName);
    mkdirSync(workspace, { recursive: true });
    const workspaceDb = new BetterSqlite3(join(workspace, 'state.vscdb'));
    workspaceDb.exec(
      'CREATE TABLE ItemTable (key TEXT PRIMARY KEY, value TEXT)',
    );
    workspaceDb.close();
    await import('node:fs/promises').then(({ writeFile }) =>
      writeFile(
        join(workspace, 'workspace.json'),
        JSON.stringify({ folder: 'file:///Users/test/migrated-project' }),
      ),
    );
    try {
      const info = await new CursorAdapter(dbPath).parseSessionInfo(
        `${dbPath}?composer=migrated`,
      );
      expect(info?.cwd).toBe('/Users/test/migrated-project');
      expect(info?.project).toBe('migrated-project');
      expect(info?.displayTitle).toBe('Official migrated Cursor title');
      expect(info?.summary).toBe('Nested migrated digest');
    } finally {
      rmSync(tmpDir, { recursive: true, force: true });
    }
  });

  it('caps official titles by characters without splitting emoji (repro)', async () => {
    const tmpDir = join(tmpdir(), `engram-cursor-title-cap-${Date.now()}`);
    mkdirSync(tmpDir, { recursive: true });
    const dbPath = join(tmpDir, 'state.vscdb');
    const expectedTitle = `${'a'.repeat(119)}👩🏽‍💻`;
    const db = new BetterSqlite3(dbPath);
    db.exec('CREATE TABLE cursorDiskKV (key TEXT PRIMARY KEY, value TEXT)');
    db.prepare('INSERT INTO cursorDiskKV (key, value) VALUES (?, ?)').run(
      'composerData:emoji-title',
      JSON.stringify({
        composerId: 'emoji-title',
        name: `${expectedTitle} tail`,
        createdAt: 1_700_000_000_000,
        lastUpdatedAt: 1_700_000_000_000,
        conversation: [{ type: 1, text: 'question' }],
      }),
    );
    db.close();
    try {
      const info = await new CursorAdapter(dbPath).parseSessionInfo(
        `${dbPath}?composer=emoji-title`,
      );
      expect(info?.displayTitle).toBe(expectedTitle);
    } finally {
      rmSync(tmpDir, { recursive: true, force: true });
    }
  });

  it('fails closed for two global composerHeader workspace candidates (repro)', async () => {
    const tmpDir = join(
      tmpdir(),
      `engram-cursor-header-conflict-${Date.now()}`,
    );
    const globalStorage = join(tmpDir, 'globalStorage');
    const workspaceStorage = join(tmpDir, 'workspaceStorage');
    const dbPath = join(globalStorage, 'state.vscdb');
    mkdirSync(globalStorage, { recursive: true });
    mkdirSync(workspaceStorage, { recursive: true });
    const db = new BetterSqlite3(dbPath);
    db.exec(
      'CREATE TABLE cursorDiskKV (key TEXT PRIMARY KEY, value TEXT); CREATE TABLE ItemTable (key TEXT PRIMARY KEY, value TEXT)',
    );
    db.prepare('INSERT INTO cursorDiskKV (key, value) VALUES (?, ?)').run(
      'composerData:conflict',
      JSON.stringify({
        composerId: 'conflict',
        createdAt: 1_700_000_000_000,
        lastUpdatedAt: 1_700_000_000_000,
        conversation: [{ type: 1, text: 'question' }],
      }),
    );
    db.prepare('INSERT INTO ItemTable (key, value) VALUES (?, ?)').run(
      'composer.composerHeaders',
      JSON.stringify({
        allComposers: [
          { composerId: 'conflict', workspaceIdentifier: { id: 'first' } },
          { composerId: 'conflict', workspaceIdentifier: { id: 'second' } },
        ],
      }),
    );
    db.close();
    for (const [name, folder] of [
      ['first', '/Users/test/first'],
      ['second', '/Users/test/second'],
    ]) {
      const workspace = join(workspaceStorage, name);
      mkdirSync(workspace, { recursive: true });
      writeFileSync(
        join(workspace, 'workspace.json'),
        JSON.stringify({ folder: `file://${folder}` }),
      );
      const workspaceDb = new BetterSqlite3(join(workspace, 'state.vscdb'));
      workspaceDb.exec(
        'CREATE TABLE ItemTable (key TEXT PRIMARY KEY, value TEXT)',
      );
      workspaceDb.close();
    }
    try {
      const info = await new CursorAdapter(dbPath).parseSessionInfo(
        `${dbPath}?composer=conflict`,
      );
      expect(info?.cwd).toBe('');
      expect(info?.project).toBeUndefined();
    } finally {
      rmSync(tmpDir, { recursive: true, force: true });
    }
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

  describe('cwd ownership ignores composer context', () => {
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

    it('does not use folderSelections without a unique workspace owner', async () => {
      const a = new CursorAdapter(dbPath);
      const info = await a.parseSessionInfo(`${dbPath}?composer=with-folder`);
      expect(info?.cwd).toBe('');
    });

    it('does not use fileSelections without a unique workspace owner', async () => {
      const a = new CursorAdapter(dbPath);
      const info = await a.parseSessionInfo(`${dbPath}?composer=with-file`);
      expect(info?.cwd).toBe('');
    });

    it('returns empty string when no context signal exists', async () => {
      const a = new CursorAdapter(dbPath);
      const info = await a.parseSessionInfo(`${dbPath}?composer=empty-context`);
      expect(info?.cwd).toBe('');
    });
  });

  describe('cwd ownership context edge cases', () => {
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

    it('does not infer cwd from a fallback fileSelection', async () => {
      const a = new CursorAdapter(dbPath);
      const info = await a.parseSessionInfo(`${dbPath}?composer=folder-empty`);
      expect(info?.cwd).toBe('');
    });

    it('does not pass through a relative fileSelection', async () => {
      const a = new CursorAdapter(dbPath);
      const info = await a.parseSessionInfo(`${dbPath}?composer=rel-file`);
      expect(info?.cwd).toBe('');
    });
  });

  describe('cwd ownership ignores remaining context edge cases', () => {
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

    it('does not scan context selections for workspace ownership', async () => {
      const a = new CursorAdapter(dbPath);
      const info = await a.parseSessionInfo(`${dbPath}?composer=second-folder`);
      expect(info?.cwd).toBe('');
    });

    it('does not accept a symlink-like context folder as ownership', async () => {
      const a = new CursorAdapter(dbPath);
      const info = await a.parseSessionInfo(`${dbPath}?composer=symlink`);
      expect(info?.cwd).toBe('');
    });
  });
});
