// MCP-layer tests for project_* tools. Correctness of the underlying
// orchestrator / undo / recover is covered by Phase 3 integration tests;
// these only verify the thin handler wrappers pass params through and
// return the expected structured shape.

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
import { Database } from '../../src/core/db.js';
import { encodeCC } from '../../src/core/project-move/encode-cc.js';
import {
  handleProjectArchive,
  handleProjectListMigrations,
  handleProjectMove,
  handleProjectMoveBatch,
  handleProjectRecover,
  handleProjectReview,
  handleProjectUndo,
} from '../../src/tools/project.js';

describe('project MCP tools', () => {
  let tmp: string;
  let home: string;
  let db: Database;
  let src: string;
  let dst: string;

  beforeEach(() => {
    tmp = mkdtempSync(join(tmpdir(), 'engram-mcp-project-'));
    home = join(tmp, 'home');
    mkdirSync(home);
    // 6 source roots
    for (const p of [
      '.claude/projects',
      '.codex/sessions',
      '.gemini/tmp',
      '.local/share/opencode',
      '.antigravity',
      '.copilot',
    ]) {
      mkdirSync(join(home, p), { recursive: true });
    }
    db = new Database(join(tmp, 'engram.sqlite'));

    src = join(tmp, 'proj', 'old');
    dst = join(tmp, 'proj', 'new');
    mkdirSync(src, { recursive: true });
    writeFileSync(join(src, 'README.md'), '# old');

    // Plant a CC session file so project_move has something to patch
    const ccOld = join(home, '.claude', 'projects', encodeCC(src));
    mkdirSync(ccOld);
    writeFileSync(
      join(ccOld, 'session.jsonl'),
      `{"cwd":"${src}","msg":"hello"}\n`,
    );
  });

  afterEach(() => {
    db.close();
    rmSync(tmp, { recursive: true, force: true });
  });

  // We can't easily pass `home` through the MCP handlers (they don't take it
  // and rely on homedir()). Tests override via HOME env var for this block.
  const withHome = async (fn: () => Promise<void>): Promise<void> => {
    const orig = process.env.HOME;
    process.env.HOME = home;
    try {
      await fn();
    } finally {
      process.env.HOME = orig;
    }
  };

  it('project_move returns committed PipelineResult', async () => {
    await withHome(async () => {
      const r = await handleProjectMove(db, { src, dst });
      expect(r.state).toBe('committed');
      expect(r.moveStrategy).toBe('rename');
      expect(existsSync(dst)).toBe(true);
      expect(r.migrationId).toMatch(/^[0-9a-f-]{36}$/);
    });
  });

  it('project_move dry_run returns dry-run state without FS changes', async () => {
    await withHome(async () => {
      const r = await handleProjectMove(db, { src, dst, dry_run: true });
      expect(r.state).toBe('dry-run');
      expect(existsSync(src)).toBe(true);
      expect(existsSync(dst)).toBe(false);
    });
  });

  it('project_archive auto-suggests category for README-only dirs', async () => {
    await withHome(async () => {
      const r = await handleProjectArchive(db, { src });
      expect(r.state).toBe('committed');
      expect(r.archive.category).toBe('空项目');
      expect(r.archive.reason).toMatch(/README|empty/i);
    });
  });

  it('project_archive `to` forces category even when ambiguous', async () => {
    // Make src ambiguous: non-empty, non-git, >1 file
    writeFileSync(join(src, 'a.txt'), 'a');
    await withHome(async () => {
      const r = await handleProjectArchive(db, { src, to: '归档完成' });
      expect(r.archive.category).toBe('归档完成');
    });
  });

  it('project_review returns structured own/other classification', async () => {
    await withHome(async () => {
      await handleProjectMove(db, { src, dst });
      // Planted session has been patched; old path no longer references it
      const r = await handleProjectReview({ old_path: src, new_path: dst });
      expect(Array.isArray(r.own)).toBe(true);
      expect(Array.isArray(r.other)).toBe(true);
      expect(r.own).toEqual([]);
    });
  });

  it('project_list_migrations returns row array', async () => {
    await withHome(async () => {
      await handleProjectMove(db, { src, dst });
      const rows = handleProjectListMigrations(db, {});
      expect(rows.length).toBe(1);
      expect(rows[0].state).toBe('committed');
      expect(rows[0].oldPath).toBe(src);
      expect(rows[0].newPath).toBe(dst);
    });
  });

  it('project_undo reverses a committed migration', async () => {
    await withHome(async () => {
      const forward = await handleProjectMove(db, { src, dst });
      const back = await handleProjectUndo(db, {
        migration_id: forward.migrationId,
      });
      expect(back.state).toBe('committed');
      expect(existsSync(src)).toBe(true);
      expect(existsSync(dst)).toBe(false);
    });
  });

  it('project_recover returns empty when no stuck migrations', async () => {
    await withHome(async () => {
      const r = await handleProjectRecover(db, {});
      expect(r).toEqual([]);
    });
  });

  it('project_move_batch runs inline YAML doc', async () => {
    const alt = join(tmp, 'proj', 'alt');
    const yaml = `
version: 1
operations:
  - src: ${src}
    dst: ${alt}
    note: batch smoke
`;
    await withHome(async () => {
      const r = await handleProjectMoveBatch(db, { yaml });
      expect(r.completed.length).toBe(1);
      expect(r.failed).toEqual([]);
      expect(existsSync(alt)).toBe(true);
    });
  });

  it('project_move_batch throws on continue_from (not-yet-supported)', async () => {
    const yaml = `
version: 1
continue_from: abc123
operations:
  - { src: /a, dst: /b }
`;
    await withHome(async () => {
      await expect(handleProjectMoveBatch(db, { yaml })).rejects.toThrow(
        /continue_from/,
      );
    });
  });

  it('project_archive dry_run returns suggestion without FS changes', async () => {
    await withHome(async () => {
      const r = await handleProjectArchive(db, { src, dry_run: true });
      expect(r.state).toBe('dry-run');
      expect(r.archive.category).toBe('空项目');
      expect(existsSync(src)).toBe(true); // untouched
      expect(db.listMigrations()).toEqual([]); // no log row
    });
  });

  it('project_archive accepts English alias "archived-done"', async () => {
    writeFileSync(join(src, 'extra.txt'), 'x'); // make ambiguous
    await withHome(async () => {
      const r = await handleProjectArchive(db, { src, to: 'archived-done' });
      expect(r.archive.category).toBe('归档完成');
    });
  });

  it('project_archive still accepts legacy "completed" for backwards-compat', async () => {
    writeFileSync(join(src, 'extra.txt'), 'x');
    await withHome(async () => {
      const r = await handleProjectArchive(db, { src, to: 'completed' });
      expect(r.archive.category).toBe('归档完成');
    });
  });

  it('project_archive rejects unknown category', async () => {
    await withHome(async () => {
      await expect(
        handleProjectArchive(db, { src, to: 'invalid-bucket' }),
      ).rejects.toThrow(/unknown category/);
    });
  });

  it('project_move expands ~ in paths and echoes resolved result', async () => {
    // Gemini M7: AI sees `resolved.src/dst` so it knows which physical paths
    // engram actually used. Avoids the "I asked for ~/proj, got something
    // else" hallucination loop.
    // Plant src under the fake home so expansion + move succeed end-to-end.
    const realSrc = join(home, 'proj2');
    mkdirSync(realSrc);
    writeFileSync(join(realSrc, 'a.txt'), 'x');

    await withHome(async () => {
      const r = await handleProjectMove(db, {
        src: '~/proj2',
        dst: '~/proj2-renamed',
      });
      expect(r.state).toBe('committed');
      expect(r.resolved).toBeDefined();
      expect(r.resolved?.src).toBe(join(home, 'proj2'));
      expect(r.resolved?.dst).toBe(join(home, 'proj2-renamed'));
    });
  });

  it('project_move_batch top-level dry_run overrides YAML defaults', async () => {
    const alt = join(tmp, 'proj', 'alt-batch');
    const yaml = `
version: 1
defaults: { dry_run: false }
operations:
  - { src: ${src}, dst: ${alt} }
`;
    await withHome(async () => {
      const r = await handleProjectMoveBatch(db, {
        yaml,
        dry_run: true, // overrides YAML defaults.dry_run=false
      });
      expect(r.completed.length).toBe(1);
      expect(r.completed[0].state).toBe('dry-run');
      expect(existsSync(alt)).toBe(false); // no actual move
    });
  });

  it('project_review truncates large result arrays', async () => {
    // Plant 150 files all referencing src (more than default 100 cap).
    const codexDir = join(home, '.codex', 'sessions');
    for (let i = 0; i < 150; i++) {
      writeFileSync(join(codexDir, `ref-${i}.jsonl`), `{"cwd":"${src}"}`);
    }
    await withHome(async () => {
      const r = await handleProjectReview({
        old_path: src,
        new_path: dst,
        max_items: 100,
      });
      expect(r.own.length).toBeLessThanOrEqual(100);
      expect(r.truncated).toBeDefined();
      expect(r.truncated?.own ?? 0).toBeGreaterThan(0);
    });
  });
});
