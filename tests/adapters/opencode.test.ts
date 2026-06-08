import { mkdirSync, rmSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import Database from 'better-sqlite3';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { OpenCodeAdapter } from '../../src/adapters/opencode.js';

const __dirname = dirname(fileURLToPath(import.meta.url));
const FIXTURE_DIR = join(__dirname, '../fixtures/opencode');
const FIXTURE_DB = join(FIXTURE_DIR, 'sample.db');

beforeAll(() => {
  mkdirSync(FIXTURE_DIR, { recursive: true });
  const db = new Database(FIXTURE_DB);
  db.exec(`
    CREATE TABLE session (
      id TEXT PRIMARY KEY, project_id TEXT NOT NULL, parent_id TEXT,
      slug TEXT NOT NULL, directory TEXT NOT NULL, title TEXT NOT NULL,
      version TEXT NOT NULL, share_url TEXT, summary_additions INTEGER,
      summary_deletions INTEGER, summary_files INTEGER, summary_diffs TEXT,
      revert TEXT, permission TEXT,
      time_created INTEGER NOT NULL, time_updated INTEGER NOT NULL,
      time_compacting INTEGER, time_archived INTEGER
    );
    CREATE TABLE message (
      id TEXT PRIMARY KEY, session_id TEXT NOT NULL,
      time_created INTEGER NOT NULL, time_updated INTEGER NOT NULL,
      data TEXT NOT NULL
    );
    CREATE TABLE part (
      id TEXT PRIMARY KEY, message_id TEXT NOT NULL,
      time_created INTEGER NOT NULL, time_updated INTEGER NOT NULL,
      data TEXT NOT NULL
    );
    INSERT INTO session VALUES (
      'ses_test001', 'proj_001', NULL, 'test-session', '/Users/test/my-project',
      '实现用户登录功能', '0.0.1', NULL, 3, 10, 2, NULL, NULL, NULL,
      1770000000000, 1770000060000, NULL, NULL
    );
    INSERT INTO message VALUES (
      'msg_001', 'ses_test001', 1770000001000, 1770000001000,
      '{"role":"user","time":{"created":1770000001000}}'
    );
    INSERT INTO part VALUES (
      'part_001', 'msg_001', 1770000001000, 1770000001000,
      '{"type":"text","text":"帮我实现登录功能"}'
    );
    INSERT INTO message VALUES (
      'msg_002', 'ses_test001', 1770000010000, 1770000010000,
      '{"role":"assistant","time":{"created":1770000010000,"completed":1770000015000},"tokens":{"input":123,"output":45,"reasoning":5,"cache":{"read":67,"write":8}}}'
    );
    INSERT INTO part VALUES (
      'part_002', 'msg_002', 1770000010000, 1770000010000,
      '{"type":"text","text":"好的，我来实现登录功能。"}'
    );
  `);
  db.close();
});

afterAll(() => {
  try {
    rmSync(FIXTURE_DB);
  } catch {
    /* ignore */
  }
});

describe('OpenCodeAdapter', () => {
  const adapter = new OpenCodeAdapter(FIXTURE_DB);

  it('name is opencode', () => {
    expect(adapter.name).toBe('opencode');
  });

  it('listSessionFiles yields virtual paths', async () => {
    const files: string[] = [];
    for await (const f of adapter.listSessionFiles()) files.push(f);
    expect(files).toHaveLength(1);
    expect(files[0]).toContain('ses_test001');
  });

  it('parseSessionInfo extracts metadata from virtual path', async () => {
    const files: string[] = [];
    for await (const f of adapter.listSessionFiles()) files.push(f);
    const info = await adapter.parseSessionInfo(files[0]);
    expect(info).not.toBeNull();
    expect(info?.id).toBe('ses_test001');
    expect(info?.source).toBe('opencode');
    expect(info?.cwd).toBe('/Users/test/my-project');
    expect(info?.summary).toBe('实现用户登录功能');
    expect(info?.messageCount).toBe(2);
  });

  it('streamMessages yields messages', async () => {
    const files: string[] = [];
    for await (const f of adapter.listSessionFiles()) files.push(f);
    const messages = [];
    for await (const msg of adapter.streamMessages(files[0]))
      messages.push(msg);
    expect(messages.length).toBeGreaterThanOrEqual(1);
  });

  it('streamMessages attaches assistant token usage including reasoning tokens', async () => {
    const files: string[] = [];
    for await (const f of adapter.listSessionFiles()) files.push(f);
    const messages = [];
    for await (const msg of adapter.streamMessages(files[0]))
      messages.push(msg);
    expect(messages.at(-1)?.usage).toEqual({
      inputTokens: 123,
      outputTokens: 50,
      cacheReadTokens: 67,
      cacheCreationTokens: 8,
    });
  });

  it('streamMessages normalizes text part type case and whitespace', async () => {
    const { mkdtempSync, copyFileSync, rmSync: rm } = require('node:fs');
    const { tmpdir } = require('node:os');
    const base = mkdtempSync(join(tmpdir(), 'engram-oc-type-'));
    const driftDb = join(base, 'opencode.db');
    copyFileSync(FIXTURE_DB, driftDb);
    const db = new Database(driftDb);
    try {
      db.prepare('UPDATE part SET data = ? WHERE id = ?').run(
        '{"type":" Text ","text":"帮我实现登录功能"}',
        'part_001',
      );
    } finally {
      db.close();
    }

    try {
      const driftAdapter = new OpenCodeAdapter(driftDb);
      const files: string[] = [];
      for await (const f of driftAdapter.listSessionFiles()) files.push(f);
      const messages = [];
      for await (const msg of driftAdapter.streamMessages(files[0]))
        messages.push(msg);
      expect(messages[0]?.content).toBe('帮我实现登录功能');
    } finally {
      rm(base, { recursive: true, force: true });
    }
  });

  it('sizeBytes reflects the session payload, not the whole shared SQLite file', async () => {
    const files: string[] = [];
    for await (const f of adapter.listSessionFiles()) files.push(f);
    const info = await adapter.parseSessionInfo(files[0]);
    expect(info?.sizeBytes).toBeGreaterThan(0);
    // The fixture DB itself is at least a few KB; a correct per-session size
    // is bounded by the message + title bytes, far below the whole-file size.
    const wholeDbBytes = require('node:fs').statSync(FIXTURE_DB).size;
    expect(info?.sizeBytes).toBeLessThan(wholeDbBytes);
  });

  it('splits the virtual path from the right so a db path with "::" still works (R5-33)', async () => {
    // Copy the fixture DB into a directory whose name contains "::". The
    // locator becomes `<dir::with::colons>/db.db::ses_test001`; a naive
    // first-"::" split would mis-slice the db path. Splitting from the right
    // (session ids never contain "::") keeps it correct.
    const { mkdtempSync, copyFileSync, rmSync: rm } = require('node:fs');
    const { tmpdir } = require('node:os');
    const base = mkdtempSync(join(tmpdir(), 'engram-oc-colon-'));
    const weirdDir = join(base, 'a::b::c');
    mkdirSync(weirdDir, { recursive: true });
    const weirdDb = join(weirdDir, 'opencode.db');
    copyFileSync(FIXTURE_DB, weirdDb);
    try {
      const colonAdapter = new OpenCodeAdapter(weirdDb);
      const files: string[] = [];
      for await (const f of colonAdapter.listSessionFiles()) files.push(f);
      expect(files).toHaveLength(1);
      expect(files[0]).toBe(`${weirdDb}::ses_test001`);
      const info = await colonAdapter.parseSessionInfo(files[0]);
      expect(info?.id).toBe('ses_test001');
      expect(info?.cwd).toBe('/Users/test/my-project');
      expect(await colonAdapter.isAccessible(files[0])).toBe(true);
    } finally {
      rm(base, { recursive: true, force: true });
    }
  });
});
