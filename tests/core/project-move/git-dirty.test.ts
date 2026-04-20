import { execFileSync } from 'node:child_process';
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { checkGitDirty } from '../../../src/core/project-move/git-dirty.js';

describe('checkGitDirty', () => {
  let tmp: string;
  beforeEach(() => {
    tmp = mkdtempSync(join(tmpdir(), 'engram-git-dirty-'));
  });
  afterEach(() => {
    rmSync(tmp, { recursive: true, force: true });
  });

  it('reports isGitRepo=false for non-git dir', async () => {
    mkdirSync(join(tmp, 'proj'));
    writeFileSync(join(tmp, 'proj', 'x.txt'), 'hi');
    const r = await checkGitDirty(join(tmp, 'proj'));
    expect(r.isGitRepo).toBe(false);
    expect(r.dirty).toBe(false);
  });

  it('reports clean repo as dirty=false', async () => {
    const proj = join(tmp, 'proj');
    mkdirSync(proj);
    writeFileSync(join(proj, 'x.txt'), 'hi');
    execFileSync('git', ['init', '-q'], { cwd: proj });
    execFileSync('git', ['config', 'user.email', 't@t'], { cwd: proj });
    execFileSync('git', ['config', 'user.name', 't'], { cwd: proj });
    execFileSync('git', ['add', '.'], { cwd: proj });
    execFileSync('git', ['commit', '-qm', 'init'], { cwd: proj });
    const r = await checkGitDirty(proj);
    expect(r.isGitRepo).toBe(true);
    expect(r.dirty).toBe(false);
  });

  it('reports dirty repo and distinguishes untrackedOnly', async () => {
    const proj = join(tmp, 'proj');
    mkdirSync(proj);
    writeFileSync(join(proj, 'tracked.txt'), 'base');
    execFileSync('git', ['init', '-q'], { cwd: proj });
    execFileSync('git', ['config', 'user.email', 't@t'], { cwd: proj });
    execFileSync('git', ['config', 'user.name', 't'], { cwd: proj });
    execFileSync('git', ['add', '.'], { cwd: proj });
    execFileSync('git', ['commit', '-qm', 'init'], { cwd: proj });

    // Add only an untracked file
    writeFileSync(join(proj, 'new.txt'), 'hi');
    let r = await checkGitDirty(proj);
    expect(r.dirty).toBe(true);
    expect(r.untrackedOnly).toBe(true);

    // Modify tracked file too → no longer untrackedOnly
    writeFileSync(join(proj, 'tracked.txt'), 'changed');
    r = await checkGitDirty(proj);
    expect(r.dirty).toBe(true);
    expect(r.untrackedOnly).toBe(false);
  });
});
