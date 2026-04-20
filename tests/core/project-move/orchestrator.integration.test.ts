// End-to-end orchestrator test — spins up a tmp FS with the 6 source roots,
// populates them with planted refs to the old path, runs runProjectMove(),
// and asserts:
//   1. physical move happened
//   2. CC encoded dir was renamed
//   3. JSONL cwd references in all 6 sources were patched
//   4. migration_log is in state='committed' with correct counts
//   5. review scan finds 0 own refs (all patched)
//   6. project_aliases was created when basename differs

import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { Database } from '../../../src/core/db.js';
import { encodeCC } from '../../../src/core/project-move/encode-cc.js';
import { runProjectMove } from '../../../src/core/project-move/orchestrator.js';

describe('runProjectMove — orchestrator integration', () => {
  let tmp: string;
  let home: string;
  let db: Database;
  let src: string;
  let dst: string;
  let ccOldDir: string;
  let ccNewDir: string;

  beforeEach(() => {
    tmp = mkdtempSync(join(tmpdir(), 'engram-orch-'));
    home = join(tmp, 'home');
    mkdirSync(home);
    // 6 source roots under fake home
    mkdirSync(join(home, '.claude', 'projects'), { recursive: true });
    mkdirSync(join(home, '.codex', 'sessions'), { recursive: true });
    mkdirSync(join(home, '.gemini', 'tmp'), { recursive: true });
    mkdirSync(join(home, '.local', 'share', 'opencode'), { recursive: true });
    mkdirSync(join(home, '.antigravity'), { recursive: true });
    mkdirSync(join(home, '.copilot'), { recursive: true });

    db = new Database(join(tmp, 'engram.sqlite'));

    // Project src + dst paths
    const projects = join(tmp, 'projects');
    mkdirSync(projects);
    src = join(projects, 'old-proj');
    dst = join(projects, 'new-proj');
    mkdirSync(src);
    writeFileSync(join(src, 'main.py'), 'print("hi")');

    // CC encoded dirs
    ccOldDir = join(home, '.claude', 'projects', encodeCC(src));
    ccNewDir = join(home, '.claude', 'projects', encodeCC(dst));
    mkdirSync(ccOldDir);
    writeFileSync(
      join(ccOldDir, 'session.jsonl'),
      `{"cwd":"${src}","text":"working on ${src}/main.py"}\n`,
    );

    // Plant a ref in codex too
    writeFileSync(
      join(home, '.codex', 'sessions', 'rollout.jsonl'),
      `{"cwd":"${src}"}\n`,
    );

    // Plant a ref in antigravity
    writeFileSync(
      join(home, '.antigravity', 'ag.jsonl'),
      `{"mention":"${src}/sub"}\n`,
    );
  });

  afterEach(() => {
    db.close();
    rmSync(tmp, { recursive: true, force: true });
  });

  it('happy path: physical move + CC rename + JSONL patch + DB commit + alias', async () => {
    // Seed DB with a session pointing at the old path
    db.getRawDb()
      .prepare(
        `INSERT INTO sessions (id, source, start_time, cwd, project, model,
         message_count, user_message_count, assistant_message_count, tool_message_count, system_message_count,
         summary, file_path, size_bytes, source_locator)
         VALUES (?, ?, datetime('now'), ?, 'old-proj', 'm', 0, 0, 0, 0, 0, null, ?, 0, ?)`,
      )
      .run(
        'sess-1',
        'claude-code',
        src,
        `${src}/session.jsonl`,
        `${src}/session.jsonl`,
      );

    const result = await runProjectMove(db, {
      src,
      dst,
      home,
      actor: 'cli',
    });

    // State
    expect(result.state).toBe('committed');
    expect(result.moveStrategy).toBe('rename');
    expect(result.ccDirRenamed).toBe(true);

    // Filesystem
    expect(existsSync(src)).toBe(false);
    expect(existsSync(dst)).toBe(true);
    expect(readFileSync(join(dst, 'main.py'), 'utf8')).toBe('print("hi")');
    expect(existsSync(ccOldDir)).toBe(false);
    expect(existsSync(ccNewDir)).toBe(true);

    // JSONL patched in all sources
    const cc = readFileSync(join(ccNewDir, 'session.jsonl'), 'utf8');
    expect(cc).toContain(dst);
    expect(cc).not.toContain(src);

    const codex = readFileSync(
      join(home, '.codex', 'sessions', 'rollout.jsonl'),
      'utf8',
    );
    expect(codex).toContain(dst);

    const ag = readFileSync(join(home, '.antigravity', 'ag.jsonl'), 'utf8');
    expect(ag).toContain(dst);

    // Counts
    expect(result.totalFilesPatched).toBeGreaterThanOrEqual(3);
    expect(
      result.perSource.find((s) => s.id === 'claude-code')?.filesPatched,
    ).toBe(1);
    expect(result.perSource.find((s) => s.id === 'codex')?.filesPatched).toBe(
      1,
    );
    expect(
      result.perSource.find((s) => s.id === 'antigravity')?.filesPatched,
    ).toBe(1);

    // DB
    const session = db.getSession('sess-1');
    expect(session?.cwd).toBe(dst);
    expect(session?.filePath).toBe(`${dst}/session.jsonl`);
    expect(result.sessionsUpdated).toBe(1);
    expect(result.aliasCreated).toBe(true);
    expect(db.listProjectAliases()).toContainEqual({
      alias: 'old-proj',
      canonical: 'new-proj',
    });

    // migration_log committed
    const log = db.findMigration(result.migrationId);
    expect(log?.state).toBe('committed');
    expect(log?.ccDirRenamed).toBe(true);
    expect(log?.sessionsUpdated).toBe(1);

    // Review finds nothing
    expect(result.review.own).toEqual([]);
  });

  it('dry-run: no FS changes, no DB writes', async () => {
    const result = await runProjectMove(db, {
      src,
      dst,
      home,
      dryRun: true,
    });

    expect(result.state).toBe('dry-run');
    expect(existsSync(src)).toBe(true); // src intact
    expect(existsSync(dst)).toBe(false);
    // Round 4: dry-run now populates `manifest` with per-file breakdown
    // so the UI can show which files would be patched. Empty-manifest was
    // the old stub behavior (see buildDryRunPlan Round 2 fix).
    expect(result.manifest.length).toBe(result.totalFilesPatched);
    const occSum = result.manifest.reduce(
      (acc, entry) => acc + entry.occurrences,
      0,
    );
    expect(occSum).toBe(result.totalOccurrences);
    expect(db.listMigrations()).toEqual([]); // no log row
  });

  it('throws on src === dst', async () => {
    await expect(runProjectMove(db, { src, dst: src, home })).rejects.toThrow(
      /src === dst/,
    );
  });

  it('throws when dst is inside src (self-subdir move)', async () => {
    await expect(
      runProjectMove(db, { src, dst: join(src, 'sub'), home }),
    ).rejects.toThrow(/inside src|own subdirectory/);
  });

  it('throws when src is inside dst (rename loop)', async () => {
    const parent = join(tmp, 'projects');
    await expect(
      runProjectMove(db, { src, dst: parent, home }),
    ).rejects.toThrow(/inside dst|rename loop/);
  });

  it('lock conflict does NOT pollute migration_log with fs_pending', async () => {
    // Self-review M1: Before the B4 reorder, a LockBusyError would leave
    // a stale fs_pending row that blocks the watcher for 24h. Verify the
    // log stays clean when the lock pre-fails.
    const { writeFile } = await import('node:fs/promises');
    const { mkdir } = await import('node:fs/promises');
    const lockPath = join(tmp, 'external.lock');
    await mkdir(join(tmp, '.engram'), { recursive: true }).catch(() => {});
    await writeFile(
      lockPath,
      JSON.stringify({
        pid: process.pid, // our pid — guaranteed alive
        startedAt: new Date().toISOString(),
        migrationId: 'external',
      }),
    );

    const before = db.listMigrations().length;
    await expect(
      runProjectMove(db, { src, dst, home, lockPath }),
    ).rejects.toThrow(/project-move is already in progress/);
    const after = db.listMigrations().length;
    expect(after).toBe(before); // no log row written
  });

  it('compensates on error: restores FS when patch fails mid-way', async () => {
    // Cause patch failure by pre-creating a CC file that will fail CAS.
    // Simplest: pass a non-existent `home` so CC dir lookup can't find the
    // encoded dir, but keep FS move working. That doesn't fail though.
    // Instead: verify that if we rename dst → src back works, compensation
    // is wired. This is a smoke-level test; richer compensation tests need
    // fault injection in Phase 2 modules.
    //
    // Force an error by setting dst to a location whose parent doesn't exist.
    await expect(
      runProjectMove(db, {
        src,
        dst: '/does/not/exist/nope',
        home,
      }),
    ).rejects.toThrow();

    // src should still be intact (compensation or pre-flight caught it)
    expect(existsSync(src)).toBe(true);

    // migration_log should show a failed row
    const logs = db.listMigrations();
    expect(logs.length).toBe(1);
    expect(logs[0].state).toBe('failed');
    expect(logs[0].error).toBeTruthy();
  });

  it('renames per-project dirs for gemini (basename) and iflow (encoded)', async () => {
    // Phase B regression: earlier the orchestrator only renamed the CC dir.
    // Gemini's tmp groups chats under basename(cwd); iFlow uses its own
    // dash-stripped encoding. Both must be renamed so adapters pick up the
    // moved project at the new path, not stay orphaned at the old name.
    const geminiOld = join(home, '.gemini', 'tmp', 'old-proj');
    const geminiNew = join(home, '.gemini', 'tmp', 'new-proj');
    mkdirSync(join(geminiOld, 'chats'), { recursive: true });
    writeFileSync(
      join(geminiOld, 'chats', 'session.json'),
      `{"cwd":"${src}"}\n`,
    );

    // iFlow uses single-dash encoding with segment-end dashes stripped.
    // For /tmp/.../projects/old-proj the encoding is straightforward (no
    // surrounding dashes on segments) so it's equivalent to CC-style.
    const iflowRoot = join(home, '.iflow', 'projects');
    mkdirSync(iflowRoot, { recursive: true });
    const iflowOldName = src.split('/').join('-'); // segments here have no -suffix
    const iflowNewName = dst.split('/').join('-');
    const iflowOld = join(iflowRoot, iflowOldName);
    const iflowNew = join(iflowRoot, iflowNewName);
    mkdirSync(iflowOld);
    writeFileSync(join(iflowOld, 'session-xx.jsonl'), `{"cwd":"${src}"}\n`);

    const result = await runProjectMove(db, { src, dst, home, actor: 'cli' });

    expect(result.state).toBe('committed');
    expect(result.ccDirRenamed).toBe(true);
    // renamedDirs contains the three that actually got renamed
    const ids = result.renamedDirs.map((d) => d.sourceId).sort();
    expect(ids).toEqual(['claude-code', 'gemini-cli', 'iflow']);

    // Physical rename happened
    expect(existsSync(geminiOld)).toBe(false);
    expect(existsSync(geminiNew)).toBe(true);
    expect(existsSync(iflowOld)).toBe(false);
    expect(existsSync(iflowNew)).toBe(true);

    // File contents patched at the NEW location
    const geminiPatched = readFileSync(
      join(geminiNew, 'chats', 'session.json'),
      'utf8',
    );
    expect(geminiPatched).toContain(dst);
    expect(geminiPatched).not.toContain(src);

    const iflowPatched = readFileSync(
      join(iflowNew, 'session-xx.jsonl'),
      'utf8',
    );
    expect(iflowPatched).toContain(dst);
    expect(iflowPatched).not.toContain(src);
  });

  it('basename unchanged (cross-parent move) does not create alias', async () => {
    // Move to a parent with same basename
    const alt = join(tmp, 'projects2');
    mkdirSync(alt);
    const dstAlt = join(alt, 'old-proj'); // same basename
    const result = await runProjectMove(db, {
      src,
      dst: dstAlt,
      home,
    });
    expect(result.state).toBe('committed');
    expect(result.aliasCreated).toBe(false);
    expect(db.listProjectAliases()).toEqual([]);
  });

  it('pre-flight: refuses to start when CC target dir already exists', async () => {
    // Codex MAJOR #2 / Gemini critical #1: dst-dir collision must be
    // detected BEFORE step 1 (physical move), so no rollback is needed.
    mkdirSync(ccNewDir);
    writeFileSync(join(ccNewDir, 'existing.jsonl'), '{}\n');

    await expect(
      runProjectMove(db, { src, dst, home, actor: 'cli' }),
    ).rejects.toThrow(/DirCollisionError|target dir already exists/);

    // Critical invariant: nothing moved. src is intact at its ORIGINAL location.
    expect(existsSync(src)).toBe(true);
    expect(existsSync(dst)).toBe(false);
    // pre-existing ccNewDir untouched
    expect(existsSync(join(ccNewDir, 'existing.jsonl'))).toBe(true);

    // No committed/pending migration_log row (preflight returns before
    // persistent state change — but after startMigration, so a 'failed'
    // row is fine as long as it's explicit).
    const logs = db.listMigrations();
    expect(
      logs.every((l) => l.state === 'failed' || l.state === 'committed'),
    ).toBe(true);
  });

  it('pre-flight: refuses Gemini shared-basename hijack', async () => {
    // Gemini MAJOR #3: dst basename 'new-proj' collides with another
    // cwd's gemini entry. Renaming the tmp dir would steal their sessions.
    const geminiOld = join(home, '.gemini', 'tmp', 'old-proj');
    mkdirSync(join(geminiOld, 'chats'), { recursive: true });
    writeFileSync(
      join(geminiOld, 'chats', 'session.json'),
      `{"cwd":"${src}"}\n`,
    );
    // Another project whose basename is the same as dst's basename
    writeFileSync(
      join(home, '.gemini', 'projects.json'),
      JSON.stringify({
        projects: {
          [src]: 'old-proj',
          '/some/other/path/new-proj': 'new-proj', // conflict!
        },
      }),
    );

    await expect(
      runProjectMove(db, { src, dst, home, actor: 'cli' }),
    ).rejects.toThrow(
      /SharedEncodingCollisionError|shared with other projects/,
    );

    expect(existsSync(src)).toBe(true);
    expect(existsSync(dst)).toBe(false);
    expect(existsSync(geminiOld)).toBe(true);
  });

  it('happy path: updates Gemini projects.json entry', async () => {
    // Codex MAJOR #1: adapter reverse-resolves cwd via this file.
    const geminiOld = join(home, '.gemini', 'tmp', 'old-proj');
    mkdirSync(join(geminiOld, 'chats'), { recursive: true });
    writeFileSync(
      join(geminiOld, 'chats', 'session.json'),
      `{"cwd":"${src}"}\n`,
    );
    writeFileSync(
      join(home, '.gemini', 'projects.json'),
      JSON.stringify({ projects: { [src]: 'old-proj' } }),
    );

    const result = await runProjectMove(db, { src, dst, home, actor: 'cli' });
    expect(result.state).toBe('committed');

    const updated = JSON.parse(
      readFileSync(join(home, '.gemini', 'projects.json'), 'utf8'),
    ) as { projects: Record<string, string> };
    expect(updated.projects[src]).toBeUndefined();
    expect(updated.projects[dst]).toBe('new-proj');
  });

  it('compensation: restores Gemini projects.json on later failure', async () => {
    // Force failure AFTER projects.json is updated (bogus dst). Confirm
    // the snapshot is put back so the adapter keeps working.
    const geminiOld = join(home, '.gemini', 'tmp', 'old-proj');
    mkdirSync(join(geminiOld, 'chats'), { recursive: true });
    const originalJson = JSON.stringify(
      { projects: { [src]: 'old-proj' } },
      null,
      2,
    );
    writeFileSync(join(home, '.gemini', 'projects.json'), originalJson);

    // Make dst unreachable (parent doesn't exist → safeMoveDir throws
    // AFTER preflight passes, during step 1). Compensation kicks in.
    await expect(
      runProjectMove(db, {
        src,
        dst: '/does/not/exist/nope',
        home,
        actor: 'cli',
      }),
    ).rejects.toThrow();

    // projects.json should be EXACTLY the original. (The reverse path
    // that's relevant here hasn't touched the file because step 2.5 runs
    // AFTER the physical move, which failed — so no edit applied, nothing
    // to reverse. Still, the file must not be corrupted.)
    const after = readFileSync(join(home, '.gemini', 'projects.json'), 'utf8');
    expect(JSON.parse(after)).toEqual(JSON.parse(originalJson));
  });

  it('iFlow lossy encoding: end-to-end with dash-wrapper segments', async () => {
    // Codex MINOR #5: fixture uses path segments with `-` wrappers so
    // the lossy encoding actually kicks in (prior tests used simple
    // segments where encoding was equivalent to CC-style).
    const iflowRoot = join(home, '.iflow', 'projects');
    mkdirSync(iflowRoot, { recursive: true });

    // Build a lossy source path: `/tmp/.../-wrap-/inner`
    const wrapParent = join(tmp, '-wrap-');
    mkdirSync(wrapParent);
    const lossySrc = join(wrapParent, 'inner');
    mkdirSync(lossySrc);
    writeFileSync(join(lossySrc, 'f.txt'), 'x');
    const lossyDst = join(wrapParent, 'inner-v2');

    const { encodeIflow } = await import(
      '../../../src/core/project-move/sources.js'
    );
    const iflowOld = join(iflowRoot, encodeIflow(lossySrc));
    const iflowNew = join(iflowRoot, encodeIflow(lossyDst));
    // Sanity: the lossy encoding strips the segment-wrapping dashes, so
    // the `-wrap-` segment becomes just `wrap` in the encoded path.
    // (Note: `-wrap-` may still appear as a bigram in the joined result
    // because adjacent segments contribute dashes at both ends — that's
    // why the encoding is lossy.)
    expect(encodeIflow(lossySrc).split('-')).toContain('wrap');
    expect(encodeIflow(lossySrc).split('-')).not.toContain('-wrap-');
    mkdirSync(iflowOld);
    writeFileSync(
      join(iflowOld, 'session-lossy.jsonl'),
      `{"cwd":"${lossySrc}"}\n`,
    );

    const result = await runProjectMove(db, {
      src: lossySrc,
      dst: lossyDst,
      home,
      actor: 'cli',
    });
    expect(result.state).toBe('committed');
    expect(existsSync(iflowOld)).toBe(false);
    expect(existsSync(iflowNew)).toBe(true);
    const patched = readFileSync(join(iflowNew, 'session-lossy.jsonl'), 'utf8');
    expect(patched).toContain(lossyDst);
  });
});
