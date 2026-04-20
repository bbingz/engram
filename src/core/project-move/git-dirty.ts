// src/core/project-move/git-dirty.ts — detect uncommitted changes before move
//
// Mirrors mvp.py:git_warn_if_dirty but returns structured info instead of
// printing. Orchestrator decides policy:
//   - default: warn + require user confirmation
//   - --force: proceed anyway
//   - v1.1 TODO: smart stash path for whitespace-only / untracked-only dirt
//     (plan §9 TODO #2).

import { execFile } from 'node:child_process';
import { stat } from 'node:fs/promises';
import { join } from 'node:path';
import { promisify } from 'node:util';

const execFileAsync = promisify(execFile);

export interface GitDirtyStatus {
  /** src is a git repository (contains `.git`). */
  isGitRepo: boolean;
  /** True if `git status --porcelain` produced any output. */
  dirty: boolean;
  /** True if every dirty line starts with `??` (only untracked files). */
  untrackedOnly: boolean;
  /** Raw porcelain output (trimmed), for the UI to display. */
  porcelain: string;
}

/**
 * Inspect `src` for uncommitted git state. Never throws — if git is missing
 * or the directory isn't a repo, returns `isGitRepo: false`. Orchestrator
 * handles the policy; this function is mechanism-only.
 */
export async function checkGitDirty(src: string): Promise<GitDirtyStatus> {
  let isGitRepo = false;
  try {
    const st = await stat(join(src, '.git'));
    isGitRepo = st.isDirectory() || st.isFile(); // .git can be a gitdir file
  } catch {
    return {
      isGitRepo: false,
      dirty: false,
      untrackedOnly: false,
      porcelain: '',
    };
  }

  try {
    const { stdout } = await execFileAsync(
      'git',
      ['-C', src, 'status', '--porcelain'],
      { maxBuffer: 4 * 1024 * 1024 },
    );
    const porcelain = stdout.trim();
    const dirty = porcelain.length > 0;
    const untrackedOnly =
      dirty &&
      porcelain.split('\n').every((line) => line.trimStart().startsWith('??'));
    return { isGitRepo, dirty, untrackedOnly, porcelain };
  } catch {
    // git missing or permission error — treat as "not-git" rather than blocking
    return { isGitRepo, dirty: false, untrackedOnly: false, porcelain: '' };
  }
}
