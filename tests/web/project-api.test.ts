// Tests for /api/project/* endpoints (Phase 4b.1 — powers Swift UI
// Rename/Archive/Undo flows). Uses real FS under a tmp home so the
// orchestrator's 3-phase pipeline actually runs end-to-end.

import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { Database } from '../../src/core/db.js';
import { encodeCC } from '../../src/core/project-move/encode-cc.js';
import { createApp } from '../../src/web.js';

describe('Web API — /api/project/*', () => {
  let tmp: string;
  let home: string;
  let db: Database;
  let app: ReturnType<typeof createApp>;
  let src: string;

  beforeEach(() => {
    tmp = mkdtempSync(join(tmpdir(), 'engram-project-api-'));
    home = join(tmp, 'home');
    mkdirSync(home);
    mkdirSync(join(home, '.claude', 'projects'), { recursive: true });
    mkdirSync(join(home, '.codex', 'sessions'), { recursive: true });
    mkdirSync(join(home, '.gemini', 'tmp'), { recursive: true });
    mkdirSync(join(home, '.local', 'share', 'opencode'), { recursive: true });
    mkdirSync(join(home, '.antigravity'), { recursive: true });
    mkdirSync(join(home, '.copilot'), { recursive: true });
    mkdirSync(join(home, '.iflow', 'projects'), { recursive: true });
    mkdirSync(join(home, '.engram'), { recursive: true });

    db = new Database(join(tmp, 'engram.sqlite'));
    app = createApp(db);

    const projects = join(tmp, 'projects');
    mkdirSync(projects);
    src = join(projects, 'old-proj');
    mkdirSync(src);
    writeFileSync(join(src, 'main.py'), 'print("hi")');

    const ccOldDir = join(home, '.claude', 'projects', encodeCC(src));
    mkdirSync(ccOldDir);
    writeFileSync(join(ccOldDir, 'session.jsonl'), `{"cwd":"${src}"}\n`);

    // Seed one session so /api/project/cwds has data
    db.getRawDb()
      .prepare(
        `INSERT INTO sessions (id, source, start_time, cwd, project, model,
         message_count, user_message_count, assistant_message_count, tool_message_count, system_message_count,
         summary, file_path, size_bytes, source_locator)
         VALUES (?, ?, datetime('now'), ?, 'old-proj', 'm', 0, 0, 0, 0, 0, null, ?, 0, ?)`,
      )
      .run(
        'api-sess-1',
        'claude-code',
        src,
        `${src}/session.jsonl`,
        `${src}/session.jsonl`,
      );
  });

  afterEach(() => {
    db.close();
    rmSync(tmp, { recursive: true, force: true });
  });

  it('GET /api/project/cwds returns distinct cwds for a project', async () => {
    const res = await app.request(`/api/project/cwds?project=old-proj`);
    expect(res.status).toBe(200);
    const body = (await res.json()) as { project: string; cwds: string[] };
    expect(body.project).toBe('old-proj');
    expect(body.cwds).toEqual([src]);
  });

  it('GET /api/project/cwds rejects missing project param', async () => {
    const res = await app.request('/api/project/cwds');
    expect(res.status).toBe(400);
  });

  it('GET /api/project/migrations returns empty when no migrations exist', async () => {
    const res = await app.request('/api/project/migrations');
    expect(res.status).toBe(200);
    const body = (await res.json()) as { migrations: unknown[] };
    expect(body.migrations).toEqual([]);
  });

  it('GET /api/project/migrations?state=committed filters', async () => {
    // Seed migration_log rows directly (faster than running a real move,
    // and avoids the /api/project/move endpoint trying to touch the user's
    // real home dir — there's no HTTP param to override home).
    const raw = db.getRawDb();
    raw
      .prepare(
        `INSERT INTO migration_log (id, old_path, new_path, old_basename,
       new_basename, state, started_at, dry_run, audit_note, archived,
       actor) VALUES (?, ?, ?, ?, ?, ?, datetime('now'), 0, null, 0, 'cli')`,
      )
      .run('m-com', '/a', '/b', 'a', 'b', 'committed');
    raw
      .prepare(
        `INSERT INTO migration_log (id, old_path, new_path, old_basename,
       new_basename, state, started_at, dry_run, audit_note, archived,
       actor) VALUES (?, ?, ?, ?, ?, ?, datetime('now'), 0, null, 0, 'cli')`,
      )
      .run('m-fail', '/c', '/d', 'c', 'd', 'failed');

    const listRes = await app.request(
      '/api/project/migrations?state=committed',
    );
    expect(listRes.status).toBe(200);
    const body = (await listRes.json()) as {
      migrations: Array<{ state: string; id: string }>;
    };
    expect(body.migrations.map((m) => m.id)).toEqual(['m-com']);
  });

  it('POST /api/project/move with missing src/dst returns 400', async () => {
    const res = await app.request('/api/project/move', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: '{}',
    });
    expect(res.status).toBe(400);
  });

  it('POST /api/project/undo with missing migrationId returns 400', async () => {
    const res = await app.request('/api/project/undo', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: '{}',
    });
    expect(res.status).toBe(400);
  });

  it('POST /api/project/archive with missing src returns 400', async () => {
    const res = await app.request('/api/project/archive', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: '{}',
    });
    expect(res.status).toBe(400);
  });

  // NOTE: we don't test POST /api/project/move end-to-end here because the
  // HTTP endpoint has no `home` override — a happy-path test would touch the
  // user's real ~/.claude, ~/.gemini, etc. Integration tests for the
  // orchestrator happy path live in orchestrator.integration.test.ts, which
  // uses a tmp home. The HTTP layer is kept thin intentionally, and is
  // covered by the error-path tests below (which don't invoke the pipeline).

  it('POST /api/project/undo with non-existent migrationId returns error', async () => {
    const res = await app.request('/api/project/undo', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ migrationId: 'does-not-exist' }),
    });
    expect([409, 500]).toContain(res.status);
    const body = (await res.json()) as { error?: { name: string } };
    expect(body.error).toBeTruthy();
  });
});
