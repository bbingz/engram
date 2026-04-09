// src/core/health-rules.ts
import { execFile as execFileCb } from 'node:child_process';
import { promisify } from 'node:util';
import type { Database } from './db.js';

const execFile = promisify(execFileCb);

// ── Types ────────────────────────────────────────────────────────────────────

export type ShellExecutor = (
  cmd: string,
  args: string[],
  opts?: { cwd?: string; timeout?: number },
) => Promise<{ stdout: string; stderr: string }>;

export interface HealthIssue {
  kind: string;
  severity: 'error' | 'warning' | 'info';
  message: string;
  detail?: string;
  repo?: string;
  action?: string;
}

export interface HealthCheckResult {
  issues: HealthIssue[];
  score: number;
  checkedAt: string;
}

export interface HealthCheckOptions {
  force?: boolean;
  scope?: 'project' | 'global';
  cwd?: string;
  shell?: ShellExecutor;
}

// ── Module-level cache ───────────────────────────────────────────────────────

let cachedResult: HealthCheckResult | null = null;
let cachedAt: number | null = null;
const CACHE_TTL_MS = 5 * 60 * 1000; // 5 minutes

// Per-repo npm audit cache (30 min)
const auditCache = new Map<string, { result: HealthIssue[]; ts: number }>();
const AUDIT_CACHE_TTL_MS = 30 * 60 * 1000;

// ── Default shell executor ───────────────────────────────────────────────────

const defaultShell: ShellExecutor = async (cmd, args, opts) => {
  const result = await execFile(cmd, args, {
    cwd: opts?.cwd,
    timeout: opts?.timeout ?? 10_000,
    encoding: 'utf-8',
  });
  return { stdout: result.stdout as string, stderr: result.stderr as string };
};

// ── Score computation ────────────────────────────────────────────────────────

export function computeScore(issues: HealthIssue[]): number {
  const penalty = issues.reduce((s, i) => {
    if (i.severity === 'error') return s + 10;
    if (i.severity === 'warning') return s + 3;
    return s + 1;
  }, 0);
  return Math.max(0, 100 - penalty);
}

// ── Individual checks ────────────────────────────────────────────────────────

/** Check for stale merged branches (>3 triggers). */
export async function checkStaleBranches(
  cwd: string,
  shell: ShellExecutor,
): Promise<HealthIssue[]> {
  try {
    let mainBranch = 'main';
    try {
      const r = await shell(
        'git',
        ['symbolic-ref', 'refs/remotes/origin/HEAD', '--short'],
        { cwd, timeout: 5000 },
      );
      mainBranch = r.stdout.trim().replace('origin/', '') || 'main';
    } catch {
      /* use default */
    }

    const { stdout } = await shell('git', ['branch', '--merged', mainBranch], {
      cwd,
      timeout: 5000,
    });
    const stale = stdout
      .split('\n')
      .map((b) => b.trim().replace('* ', ''))
      .filter(
        (b) =>
          b &&
          b !== mainBranch &&
          b !== 'master' &&
          b !== 'main' &&
          !b.startsWith('('),
      );
    if (stale.length > 3) {
      return [
        {
          kind: 'stale_branches',
          severity: 'info',
          message: `${stale.length} merged branches can be cleaned up`,
          detail: stale.slice(0, 5).join(', '),
          repo: cwd,
          action: 'git branch -d <branch>',
        },
      ];
    }
  } catch {
    /* not a git repo or git unavailable */
  }
  return [];
}

/** Check for large number of uncommitted changes (>20 triggers). */
export async function checkLargeUncommitted(
  cwd: string,
  shell: ShellExecutor,
): Promise<HealthIssue[]> {
  try {
    const { stdout } = await shell('git', ['status', '--porcelain'], {
      cwd,
      timeout: 5000,
    });
    const files = stdout.split('\n').filter((l) => l.trim());
    if (files.length > 20) {
      return [
        {
          kind: 'large_uncommitted',
          severity: 'warning',
          message: `${files.length} uncommitted changes`,
          detail: files
            .slice(0, 5)
            .map((f) => f.slice(3))
            .join(', '),
          repo: cwd,
          action: 'git add && git commit or git stash',
        },
      ];
    }
  } catch {
    /* not a git repo */
  }
  return [];
}

/** Check for zombie Engram daemon processes (>2 triggers). */
export async function checkZombieDaemon(
  shell: ShellExecutor,
): Promise<HealthIssue[]> {
  try {
    const { stdout } = await shell(
      'pgrep',
      ['-lf', 'engram.*daemon|daemon.*engram'],
      { timeout: 3000 },
    );
    const procs = stdout.split('\n').filter((l) => l.trim());
    if (procs.length > 2) {
      return [
        {
          kind: 'zombie_daemon',
          severity: 'warning',
          message: `${procs.length} Engram daemon processes running (expected 1)`,
          action: 'pkill -f engram.*daemon',
        },
      ];
    }
  } catch {
    /* pgrep found nothing — normal */
  }
  return [];
}

/** Check for .env* files that are not covered by .gitignore. */
export async function checkEnvSecurity(
  cwd: string,
  shell: ShellExecutor,
): Promise<HealthIssue[]> {
  try {
    // List .env* files in repo
    const { stdout: lsOut } = await shell(
      'git',
      ['ls-files', '--others', '--exclude-standard', '-z'],
      { cwd, timeout: 5000 },
    );
    const untrackedFiles = lsOut.split('\0').filter(Boolean);

    // Also check tracked .env files
    const { stdout: trackedOut } = await shell('git', ['ls-files', '-z'], {
      cwd,
      timeout: 5000,
    });
    const trackedFiles = trackedOut.split('\0').filter(Boolean);

    const envFiles = [...untrackedFiles, ...trackedFiles].filter((f) =>
      /^\.env/.test(f.split('/').pop() ?? ''),
    );

    const exposed: string[] = [];
    for (const file of envFiles) {
      try {
        await shell('git', ['check-ignore', '-q', file], {
          cwd,
          timeout: 3000,
        });
        // exit 0 = ignored (safe), exit 1 = not ignored (problem)
      } catch {
        // exit nonzero means NOT ignored
        exposed.push(file);
      }
    }

    if (exposed.length > 0) {
      return [
        {
          kind: 'env_security',
          severity: 'error',
          message: `${exposed.length} .env file(s) not in .gitignore`,
          detail: exposed.slice(0, 5).join(', '),
          repo: cwd,
          action: 'Add .env* to .gitignore',
        },
      ];
    }
  } catch {
    /* not a git repo */
  }
  return [];
}

// Processes that are expected to run long — not zombies
const PROCESS_WHITELIST = [
  /engram.*daemon/,
  /next[\s/]dev/,
  /next[\s/]start/,
  /vite/,
  /webpack-dev-server/,
  /nuxt/,
  /remix[\s/]dev/,
  /tsx watch/,
  /nodemon/,
];

/** Parse ps etime format [[dd-]hh:]mm:ss → seconds */
export function parseEtime(etime: string): number {
  const trimmed = etime.trim();
  // Format: [[dd-]hh:]mm:ss
  const parts = trimmed.split(':');
  if (parts.length === 2) {
    // mm:ss
    return parseInt(parts[0], 10) * 60 + parseInt(parts[1], 10);
  }
  if (parts.length === 3) {
    // [dd-]hh:mm:ss
    const [hourPart, min, sec] = parts;
    if (hourPart.includes('-')) {
      const [dd, hh] = hourPart.split('-');
      return (
        parseInt(dd, 10) * 86400 +
        parseInt(hh, 10) * 3600 +
        parseInt(min, 10) * 60 +
        parseInt(sec, 10)
      );
    }
    return (
      parseInt(hourPart, 10) * 3600 + parseInt(min, 10) * 60 + parseInt(sec, 10)
    );
  }
  return 0;
}

export function isOlderThan2h(etime: string): boolean {
  return parseEtime(etime) > 7200;
}

/** Check for headless node/python processes older than 2h (excluding whitelist). */
export async function checkZombieProcesses(
  shell: ShellExecutor,
): Promise<HealthIssue[]> {
  try {
    const { stdout } = await shell(
      'ps',
      ['axo', 'pid,etime,command', '--no-headers'],
      { timeout: 5000 },
    );
    const zombies: string[] = [];

    for (const line of stdout.split('\n')) {
      const trimmed = line.trim();
      if (!trimmed) continue;
      // Format: pid etime command...
      const spaceIdx = trimmed.indexOf(' ');
      if (spaceIdx === -1) continue;
      const rest = trimmed.slice(spaceIdx + 1).trim();
      const etimeEnd = rest.indexOf(' ');
      if (etimeEnd === -1) continue;
      const etime = rest.slice(0, etimeEnd);
      const command = rest.slice(etimeEnd + 1).trim();

      // Only node or python processes
      if (!/\b(node|python[23]?)\b/.test(command)) continue;
      // Skip whitelisted processes
      if (PROCESS_WHITELIST.some((r) => r.test(command))) continue;
      // Only flag if older than 2h
      if (!isOlderThan2h(etime)) continue;

      zombies.push(command.slice(0, 80));
    }

    if (zombies.length > 0) {
      return [
        {
          kind: 'zombie_processes',
          severity: 'warning',
          message: `${zombies.length} headless node/python process(es) running >2h`,
          detail: zombies.slice(0, 3).join('; '),
          action: 'Review and kill stale processes',
        },
      ];
    }
  } catch {
    /* ps unavailable */
  }
  return [];
}

/** Check for orphan worktrees (linked worktrees whose directories no longer exist). */
export async function checkWorktreeHealth(
  cwd: string,
  shell: ShellExecutor,
): Promise<HealthIssue[]> {
  try {
    const { stdout } = await shell('git', ['worktree', 'list', '--porcelain'], {
      cwd,
      timeout: 5000,
    });
    const worktrees = stdout.trim().split('\n\n').filter(Boolean);
    const orphans: string[] = [];

    for (const block of worktrees) {
      const lines = block.trim().split('\n');
      const worktreeLine = lines.find((l) => l.startsWith('worktree '));
      const prunableLine = lines.find((l) => l.startsWith('prunable'));
      if (worktreeLine && prunableLine) {
        orphans.push(worktreeLine.replace('worktree ', ''));
      }
    }

    if (orphans.length > 0) {
      return [
        {
          kind: 'worktree_health',
          severity: 'warning',
          message: `${orphans.length} orphan worktree(s) detected`,
          detail: orphans.slice(0, 3).join(', '),
          repo: cwd,
          action: 'git worktree prune',
        },
      ];
    }
  } catch {
    /* not a git repo or old git */
  }
  return [];
}

/** Run npm audit on repos with recent sessions. Uses a 30-min per-repo cache. */
export async function checkDependencySecurity(
  repoPaths: string[],
  shell: ShellExecutor,
): Promise<HealthIssue[]> {
  const issues: HealthIssue[] = [];
  const now = Date.now();

  for (const repoPath of repoPaths) {
    const cached = auditCache.get(repoPath);
    if (cached && now - cached.ts < AUDIT_CACHE_TTL_MS) {
      issues.push(...cached.result);
      continue;
    }

    try {
      // Check if package.json exists
      await shell('test', ['-f', `${repoPath}/package.json`], {
        timeout: 1000,
      });
    } catch {
      auditCache.set(repoPath, { result: [], ts: now });
      continue;
    }

    try {
      // npm audit --json is read-only, safe to run
      const { stdout } = await shell('npm', ['audit', '--json'], {
        cwd: repoPath,
        timeout: 30_000,
      });
      let data: Record<string, unknown>;
      try {
        data = JSON.parse(stdout);
      } catch {
        auditCache.set(repoPath, { result: [], ts: now });
        continue;
      }

      const metadata = data.metadata as Record<string, unknown> | undefined;
      const vulns = (metadata?.vulnerabilities as Record<string, number>) ?? {};
      const criticalCount = (vulns.critical ?? 0) + (vulns.high ?? 0);
      const modCount = vulns.moderate ?? 0;

      const repoIssues: HealthIssue[] = [];
      if (criticalCount > 0) {
        repoIssues.push({
          kind: 'dependency_security',
          severity: 'error',
          message: `${criticalCount} critical/high npm vulnerability(ies)`,
          repo: repoPath,
          action: 'npm audit fix',
        });
      } else if (modCount > 0) {
        repoIssues.push({
          kind: 'dependency_security',
          severity: 'warning',
          message: `${modCount} moderate npm vulnerability(ies)`,
          repo: repoPath,
          action: 'npm audit fix',
        });
      }

      auditCache.set(repoPath, { result: repoIssues, ts: now });
      issues.push(...repoIssues);
    } catch {
      // npm audit exits non-zero when vulnerabilities found — capture stdout anyway
      auditCache.set(repoPath, { result: [], ts: now });
    }
  }

  return issues;
}

/** Check for excessive git stashes (>5 triggers). */
export async function checkGitStash(
  cwd: string,
  shell: ShellExecutor,
): Promise<HealthIssue[]> {
  try {
    const { stdout } = await shell('git', ['stash', 'list'], {
      cwd,
      timeout: 5000,
    });
    const stashes = stdout.split('\n').filter((l) => l.trim());
    if (stashes.length > 5) {
      return [
        {
          kind: 'git_stash',
          severity: 'info',
          message: `${stashes.length} stashed changes (consider cleaning up)`,
          repo: cwd,
          action: 'git stash drop or git stash pop',
        },
      ];
    }
  } catch {
    /* not a git repo */
  }
  return [];
}

/** Check for branch divergence from upstream. */
export async function checkBranchDivergence(
  cwd: string,
  shell: ShellExecutor,
): Promise<HealthIssue[]> {
  try {
    const { stdout } = await shell(
      'git',
      ['rev-list', '--left-right', '--count', 'HEAD...@{u}'],
      { cwd, timeout: 5000 },
    );
    const [aheadStr, behindStr] = stdout.trim().split(/\s+/);
    const ahead = parseInt(aheadStr, 10) || 0;
    const behind = parseInt(behindStr, 10) || 0;

    if (behind > 20) {
      return [
        {
          kind: 'branch_divergence',
          severity: 'warning',
          message: `Branch is ${behind} commits behind upstream`,
          repo: cwd,
          action: 'git pull --rebase',
        },
      ];
    }
    if (ahead > 50) {
      return [
        {
          kind: 'branch_divergence',
          severity: 'info',
          message: `Branch is ${ahead} commits ahead of upstream`,
          repo: cwd,
          action: 'git push',
        },
      ];
    }
  } catch {
    /* no upstream tracking or not a git repo */
  }
  return [];
}

// ── Main entry point ─────────────────────────────────────────────────────────

export async function runAllHealthChecks(
  db: Database,
  options?: HealthCheckOptions,
): Promise<HealthCheckResult> {
  const now = Date.now();
  const force = options?.force ?? false;
  const scope = options?.scope ?? 'global';
  const shell = options?.shell ?? defaultShell;

  // Return cached result if within TTL and not forced
  if (!force && cachedResult && cachedAt && now - cachedAt < CACHE_TTL_MS) {
    return cachedResult;
  }

  const raw = db.getRawDb();

  // Determine repos to check
  let repoPaths: string[] = [];
  if (scope === 'project' && options?.cwd) {
    repoPaths = [options.cwd];
  } else {
    // Global: all repos from git_repos table
    const rows = raw
      .prepare('SELECT path FROM git_repos ORDER BY probed_at DESC')
      .all() as { path: string }[];
    repoPaths = rows.map((r) => r.path);
  }

  // Determine repos with sessions in last 7 days (for npm audit)
  const sevenDaysAgo = new Date(now - 7 * 24 * 60 * 60 * 1000).toISOString();
  const recentRows = raw
    .prepare(`
    SELECT DISTINCT project FROM sessions
    WHERE start_time > ? AND project IS NOT NULL
  `)
    .all(sevenDaysAgo) as { project: string }[];
  const recentProjects = new Set(recentRows.map((r) => r.project));

  // Filter repoPaths to those with recent sessions (by matching repo name)
  const reposWithRecentSessions = repoPaths.filter((p) => {
    const name = p.split('/').pop() ?? '';
    return recentProjects.has(name) || recentProjects.has(p);
  });

  const issues: HealthIssue[] = [];

  // Run per-repo checks
  await Promise.all(
    repoPaths.map(async (repoPath) => {
      const [
        staleBranches,
        largeUncommitted,
        worktreeHealth,
        gitStash,
        branchDivergence,
        envSecurity,
      ] = await Promise.all([
        checkStaleBranches(repoPath, shell),
        checkLargeUncommitted(repoPath, shell),
        checkWorktreeHealth(repoPath, shell),
        checkGitStash(repoPath, shell),
        checkBranchDivergence(repoPath, shell),
        checkEnvSecurity(repoPath, shell),
      ]);
      issues.push(
        ...staleBranches,
        ...largeUncommitted,
        ...worktreeHealth,
        ...gitStash,
        ...branchDivergence,
        ...envSecurity,
      );
    }),
  );

  // Global checks (run once)
  const [zombieDaemon, zombieProcesses, depSecurity] = await Promise.all([
    checkZombieDaemon(shell),
    checkZombieProcesses(shell),
    checkDependencySecurity(reposWithRecentSessions, shell),
  ]);
  issues.push(...zombieDaemon, ...zombieProcesses, ...depSecurity);

  const result: HealthCheckResult = {
    issues,
    score: computeScore(issues),
    checkedAt: new Date().toISOString(),
  };

  cachedResult = result;
  cachedAt = now;

  return result;
}
