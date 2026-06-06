import type { Dirent } from 'node:fs';
import { cp, lstat, readdir, readFile, rm } from 'node:fs/promises';
import { join } from 'node:path';
import {
  getSourceRoots,
  type SourceRoot,
  walkSessionFiles,
} from './sources.js';

export interface GroupedDirReconcileResult {
  scannedDirs: number;
  plannedRenames: number;
  appliedRenames: number;
  collisions: number;
  ambiguous: number;
  issues: number;
}

const EMPTY_RESULT: GroupedDirReconcileResult = {
  scannedDirs: 0,
  plannedRenames: 0,
  appliedRenames: 0,
  collisions: 0,
  ambiguous: 0,
  issues: 0,
};

const STRUCTURED_CWD_READ_CAP_BYTES = 50 * 1024 * 1024;

interface RepairPlan {
  sourceDir: string;
  targetDir: string;
}

export async function reconcileGroupedProjectDirs(
  opts: { roots?: SourceRoot[]; dryRun?: boolean } = {},
): Promise<GroupedDirReconcileResult> {
  const roots = opts.roots ?? getSourceRoots();
  const result = { ...EMPTY_RESULT };

  for (const root of roots) {
    if (!shouldReconcile(root) || root.encodeProjectDir === null) continue;
    let entries: Dirent[];
    try {
      entries = await readdir(root.path, { withFileTypes: true });
    } catch {
      continue;
    }

    for (const entry of entries) {
      const sourceDir = join(root.path, entry.name);
      if (!(await isDirectoryNoFollow(sourceDir))) continue;
      result.scannedDirs += 1;

      const scan = await structuredCwds(sourceDir);
      result.issues += scan.issues;
      const targetNames = new Set(scan.cwdValues.map(root.encodeProjectDir));
      if (targetNames.size === 0) continue;
      if (targetNames.size !== 1) {
        result.ambiguous += 1;
        continue;
      }

      const targetName = [...targetNames][0];
      if (targetName === entry.name) continue;
      const targetDir = join(root.path, targetName);
      result.plannedRenames += 1;
      if (opts.dryRun) continue;

      const applied = await apply({ sourceDir, targetDir });
      if (applied === 'applied') result.appliedRenames += 1;
      if (applied === 'collision') result.collisions += 1;
      if (applied === 'issue') result.issues += 1;
    }
  }

  return result;
}

function shouldReconcile(root: SourceRoot): boolean {
  return root.id === 'claude-code' || root.id === 'qoder';
}

async function isDirectoryNoFollow(path: string): Promise<boolean> {
  try {
    const st = await lstat(path);
    return st.isDirectory();
  } catch {
    return false;
  }
}

async function apply(
  plan: RepairPlan,
): Promise<'applied' | 'collision' | 'issue'> {
  if (await pathExists(plan.targetDir)) return 'collision';
  try {
    await cp(plan.sourceDir, plan.targetDir, {
      recursive: true,
      force: false,
      errorOnExist: true,
    });
  } catch (err) {
    if ((await pathExists(plan.targetDir)) || isExistsError(err)) {
      return 'collision';
    }
    return 'issue';
  }
  try {
    await rm(plan.sourceDir, { recursive: true, force: false });
    return 'applied';
  } catch {
    return 'issue';
  }
}

async function pathExists(path: string): Promise<boolean> {
  try {
    await lstat(path);
    return true;
  } catch {
    return false;
  }
}

function isExistsError(err: unknown): boolean {
  const code = (err as { code?: string }).code;
  return code === 'EEXIST' || code === 'ERR_FS_CP_EEXIST';
}

async function structuredCwds(
  dir: string,
): Promise<{ cwdValues: string[]; issues: number }> {
  const cwdValues = new Set<string>();
  let issues = 0;
  for await (const file of walkSessionFiles(dir, {
    maxFileBytes: STRUCTURED_CWD_READ_CAP_BYTES,
    onIssue: () => {
      issues += 1;
    },
  })) {
    let text: string;
    try {
      text = await readFile(file, 'utf8');
    } catch {
      issues += 1;
      continue;
    }
    for (const line of text.split(/\r?\n/)) {
      const cwd = extractStructuredCwd(line);
      if (cwd) cwdValues.add(cwd);
    }
  }
  return { cwdValues: [...cwdValues].sort(), issues };
}

function extractStructuredCwd(line: string): string | null {
  const trimmed = line.trim();
  if (!trimmed) return null;
  try {
    const obj = JSON.parse(trimmed) as {
      cwd?: unknown;
      payload?: { cwd?: unknown };
    };
    if (typeof obj.cwd === 'string' && obj.cwd.length > 0) return obj.cwd;
    if (typeof obj.payload?.cwd === 'string' && obj.payload.cwd.length > 0) {
      return obj.payload.cwd;
    }
  } catch {
    return null;
  }
  return null;
}
