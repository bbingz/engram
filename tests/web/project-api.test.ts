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

    // Project workspace lives *under* home so the $HOME-prefix guard
    // added in Important #2 accepts paths there when HOME is pointed
    // at this fake home via process.env.
    const projects = join(home, 'projects');
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

  it('POST /api/project/move rejects paths outside $HOME (defense-in-depth)', async () => {
    const res = await app.request('/api/project/move', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ src: '/etc/passwd', dst: '/etc/other' }),
    });
    expect(res.status).toBe(400);
    const body = (await res.json()) as {
      error: { name: string; message: string };
    };
    expect(body.error.name).toBe('InvalidPath');
    expect(body.error.message).toMatch(/must live under/);
  });

  // Phase B Step 3: actor threading + $HOME bypass for MCP ---------------
  it('unknown actor value returns 400 InvalidActor (audit hygiene)', async () => {
    const res = await app.request('/api/project/move', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ src: '~/x', dst: '~/y', actor: 'hacker' }),
    });
    expect(res.status).toBe(400);
    const body = (await res.json()) as { error: { name: string } };
    expect(body.error.name).toBe('InvalidActor');
  });

  it('POST /api/project/undo also validates actor', async () => {
    const res = await app.request('/api/project/undo', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ migrationId: 'x', actor: 'hacker' }),
    });
    expect(res.status).toBe(400);
    const body = (await res.json()) as { error: { name: string } };
    expect(body.error.name).toBe('InvalidActor');
  });

  it('POST /api/project/archive also validates actor', async () => {
    const res = await app.request('/api/project/archive', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ src: '~/x', actor: 'hacker' }),
    });
    expect(res.status).toBe(400);
    const body = (await res.json()) as { error: { name: string } };
    expect(body.error.name).toBe('InvalidActor');
  });

  // Round 2 M3: project_move_batch now routes through daemon too
  it('POST /api/project/move-batch with missing yaml returns 400', async () => {
    const res = await app.request('/api/project/move-batch', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ dryRun: true }),
    });
    expect(res.status).toBe(400);
    const body = (await res.json()) as {
      error: { name: string; message: string };
    };
    expect(body.error.name).toBe('MissingParam');
    expect(body.error.message).toMatch(/yaml/);
  });

  it('POST /api/project/move-batch dry-run runs batch pipeline', async () => {
    const savedHome = process.env.HOME;
    process.env.HOME = home;
    try {
      const yaml = [
        'version: 1',
        'defaults:',
        '  dry_run: true',
        'operations:',
        `  - src: "${src}"`,
        `    dst: "${home}/newbatch"`,
      ].join('\n');
      const res = await app.request('/api/project/move-batch', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ yaml, force: true }),
      });
      expect(res.status).toBe(200);
      const body = (await res.json()) as {
        completed: unknown[];
        failed: unknown[];
        skipped: unknown[];
      };
      // Dry-run batch succeeds — the single operation lands in `completed`
      // (dry-run is still a "successful" simulation).
      expect(body.completed.length).toBe(1);
      expect(body.failed).toEqual([]);
    } finally {
      if (savedHome) process.env.HOME = savedHome;
      else delete process.env.HOME;
    }
  });

  it('actor:mcp still respects $HOME confinement (Round 1 hotfix)', async () => {
    // Originally actor:'mcp' bypassed the $HOME guard on the theory that MCP
    // is a trusted local peer. The 6-way review flagged this as derivable-
    // trust — any local process could self-declare as MCP and escape the
    // guard. Hotfix: $HOME is enforced for every actor; the actor field is
    // audit-only.
    const res = await app.request('/api/project/move', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        src: '/tmp/engram-step3-no-such-src',
        dst: '/tmp/engram-step3-no-such-dst',
        actor: 'mcp',
      }),
    });
    expect(res.status).toBe(400);
    const body = (await res.json()) as {
      error: { name: string; message: string };
    };
    expect(body.error.name).toBe('InvalidPath');
    expect(body.error.message).toMatch(/must live under/);
  });

  it('actor:swift-ui (default) enforces $HOME confinement', async () => {
    const res = await app.request('/api/project/move', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        src: '/tmp/engram-step3-no-such-src',
        dst: '/tmp/engram-step3-no-such-dst',
        // no actor → default 'swift-ui'
      }),
    });
    expect(res.status).toBe(400);
    const body = (await res.json()) as {
      error: { name: string; message: string };
    };
    expect(body.error.name).toBe('InvalidPath');
    expect(body.error.message).toMatch(/must live under/);
  });

  it('POST /api/project/move resolves ~/../.. traversal and rejects it', async () => {
    // `~/../../etc` expands to /Users/example/../../etc, which pathResolve
    // canonicalizes to /etc. The $HOME prefix check then rejects it.
    const res = await app.request('/api/project/move', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        src: '~/../../etc/passwd',
        dst: '~/some/legal/path',
      }),
    });
    expect(res.status).toBe(400);
    const body = (await res.json()) as { error: { name: string } };
    expect(body.error.name).toBe('InvalidPath');
  });

  // Pass 5 additions (3-way review Phase 4b rev2)
  it('POST /api/project/move with relative path returns 400 with envelope', async () => {
    const res = await app.request('/api/project/move', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ src: 'relative/src', dst: '/abs/dst' }),
    });
    expect(res.status).toBe(400);
    const body = (await res.json()) as {
      error: { name: string; message: string; retry_policy: string };
    };
    expect(body.error.name).toBe('InvalidPath');
    expect(body.error.retry_policy).toBe('never');
    expect(body.error.message).toContain('src:');
  });

  it('POST /api/project/move validation error returns structured envelope', async () => {
    const res = await app.request('/api/project/move', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: '{}',
    });
    expect(res.status).toBe(400);
    const body = (await res.json()) as {
      error: { name: string; retry_policy: string };
    };
    // Uniform envelope shape — Swift DaemonClient relies on this.
    expect(body.error).toMatchObject({
      name: 'MissingParam',
      retry_policy: 'never',
    });
  });

  it('POST with wrong bearer token returns 401 as JSON envelope', async () => {
    // Spin up a protected app for this one case — main suite is open.
    const protectedApp = createApp(db, {
      settings: { httpBearerToken: 'test-secret' },
    });
    const res = await protectedApp.request('/api/project/move', {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        Authorization: 'Bearer wrong-token',
      },
      body: JSON.stringify({ src: '/a', dst: '/b' }),
    });
    expect(res.status).toBe(401);
    // Swift client expects the envelope shape; plain text would fall through
    // to DaemonClientError.httpError and hide the reason.
    const body = (await res.json()) as {
      error: { name: string; retry_policy: string };
    };
    expect(body.error.name).toBe('Unauthorized');
    expect(body.error.retry_policy).toBe('never');
  });

  it('POST /api/project/move dry-run returns 200 contract (Swift decode target)', async () => {
    // Codex follow-up minor #5 — this test used to only assert types,
    // so the `buildDryRunPlan` stub (hardcoded 0/0) passed it. Now we
    // seed a CC session file that references `src` and assert the scan
    // returns a non-zero count. A future stub-regression will fail.
    //
    // process.env.HOME is swapped to the tmp so (a) normalizeHttpPath's
    // $HOME guard lets `src` under tmp through, and (b) the orchestrator's
    // getSourceRoots fallback picks up the fake home layout we set up in
    // beforeEach. Restored at end of test.
    const savedHome = process.env.HOME;
    process.env.HOME = home;
    try {
      const res = await app.request('/api/project/move', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          src,
          dst: `${home}/newhome`,
          dryRun: true,
          force: true, // src has no .git so this is moot, but future-proof
        }),
      });
      expect(res.status).toBe(200);
      const body = (await res.json()) as Record<string, unknown>;
      // Required fields the Swift ProjectMoveResult decoder reads
      expect(body.migrationId).toBe('dry-run');
      expect(body.state).toBe('dry-run');
      expect(typeof body.ccDirRenamed).toBe('boolean');
      expect(typeof body.totalFilesPatched).toBe('number');
      expect(typeof body.totalOccurrences).toBe('number');
      expect(typeof body.sessionsUpdated).toBe('number');
      expect(typeof body.aliasCreated).toBe('boolean');
      expect(body.review).toMatchObject({ own: [], other: [] });
      // Semantic assertion — the beforeEach seeded a CC session file
      // containing `src` as its cwd. A real scan MUST find it.
      expect(body.totalFilesPatched as number).toBeGreaterThanOrEqual(1);
      expect(body.totalOccurrences as number).toBeGreaterThanOrEqual(1);
      // Round 4: manifest must carry per-file breakdown so the Swift UI
      // can show *which* files will be patched. Previously the backend
      // returned `manifest: []` in dry-run, so the UI had nothing to
      // render — users reported flying blind.
      const manifest = body.manifest as Array<{
        path: string;
        occurrences: number;
      }>;
      expect(Array.isArray(manifest)).toBe(true);
      expect(manifest.length).toBe(body.totalFilesPatched);
      // Each entry must carry a real path + non-negative occurrences.
      for (const entry of manifest) {
        expect(typeof entry.path).toBe('string');
        expect(entry.path.length).toBeGreaterThan(0);
        expect(typeof entry.occurrences).toBe('number');
        expect(entry.occurrences).toBeGreaterThanOrEqual(0);
      }
      // Sum of manifest occurrences must match the aggregate counter —
      // otherwise the "N files · M occurrences" banner is inconsistent
      // with the expandable file list.
      const occSum = manifest.reduce((acc, e) => acc + e.occurrences, 0);
      expect(occSum).toBe(body.totalOccurrences);
    } finally {
      if (savedHome) process.env.HOME = savedHome;
      else delete process.env.HOME;
    }
  });

  it('migration_log detail includes skipped_dirs and gemini_projects_json_updated', async () => {
    // Contract regression: the Swift UI doesn't read these yet, but the
    // telemetry surface should stay stable for debugging.
    const raw = db.getRawDb();
    raw
      .prepare(
        `INSERT INTO migration_log (id, old_path, new_path, old_basename,
       new_basename, state, started_at, dry_run, audit_note, archived,
       actor, detail) VALUES (?, ?, ?, ?, ?, ?, datetime('now'), 0, null, 0, 'cli', ?)`,
      )
      .run(
        'm-contract',
        '/a/p',
        '/b/p',
        'p',
        'p',
        'committed',
        JSON.stringify({
          renamed_dirs: [{ source: 'claude-code', old: '/o', new: '/n' }],
          skipped_dirs: [{ sourceId: 'codex', reason: 'noop' }],
          gemini_projects_json_updated: false,
        }),
      );
    const listRes = await app.request('/api/project/migrations?limit=1');
    expect(listRes.status).toBe(200);
    const body = (await listRes.json()) as {
      migrations: Array<{ detail: Record<string, unknown> }>;
    };
    expect(body.migrations[0].detail).toMatchObject({
      gemini_projects_json_updated: false,
    });
  });
});
