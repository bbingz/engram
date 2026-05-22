// tests/tools/get_session.test.ts

import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { CodexAdapter } from '../../src/adapters/codex.js';
import { Database } from '../../src/core/db.js';
import { handleGetSession } from '../../src/tools/get_session.js';

const __dirname = dirname(fileURLToPath(import.meta.url));
const FIXTURE = join(__dirname, '../fixtures/codex/sample.jsonl');

describe('get_session', () => {
  let db: Database;
  let tmpDir: string;

  beforeEach(async () => {
    tmpDir = mkdtempSync(join(tmpdir(), 'get-session-test-'));
    db = new Database(join(tmpDir, 'test.sqlite'));
    const adapter = new CodexAdapter();
    const info = await adapter.parseSessionInfo(FIXTURE);
    if (info) db.upsertSession(info);
  });

  afterEach(() => {
    db.close();
    rmSync(tmpDir, { recursive: true });
  });

  it('returns session with messages', async () => {
    const adapter = new CodexAdapter();
    const result = await handleGetSession(db, adapter, {
      id: 'codex-session-001',
      page: 1,
    });
    expect(result.session).not.toBeNull();
    expect(result.messages.length).toBeGreaterThan(0);
    expect(result.totalPages).toBeGreaterThanOrEqual(1);
  });

  it('throws for unknown session id', async () => {
    const adapter = new CodexAdapter();
    await expect(
      handleGetSession(db, adapter, { id: 'nonexistent' }),
    ).rejects.toThrow('Session not found');
  });

  it('streams messages by page without buffering everything', async () => {
    const adapter = new CodexAdapter();
    // Page 1 returns the first window; with the fixture (3 user+assistant+tool
    // messages) page 1 must fit and page 2 must be empty. The key behavior is
    // that totalPages reflects the total matched count even when only a tiny
    // window is returned per call.
    const page1 = await handleGetSession(db, adapter, {
      id: 'codex-session-001',
      page: 1,
    });
    const page2 = await handleGetSession(db, adapter, {
      id: 'codex-session-001',
      page: 2,
    });
    expect(page1.messages.length).toBeGreaterThan(0);
    expect(page2.messages).toEqual([]);
    expect(page1.totalPages).toBe(page2.totalPages);
  });

  it('honors role filter before pagination', async () => {
    const adapter = new CodexAdapter();
    const r = await handleGetSession(db, adapter, {
      id: 'codex-session-001',
      page: 1,
      roles: ['user'],
    });
    expect(r.messages.every((m) => m.role === 'user')).toBe(true);
  });
});
