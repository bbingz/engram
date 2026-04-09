// tests/core/health-rules.test.ts
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { Database } from '../../src/core/db.js';
import {
  checkBranchDivergence,
  checkDependencySecurity,
  checkEnvSecurity,
  checkGitStash,
  checkLargeUncommitted,
  checkStaleBranches,
  checkWorktreeHealth,
  checkZombieDaemon,
  checkZombieProcesses,
  computeScore,
  type HealthIssue,
  isOlderThan2h,
  parseEtime,
  runAllHealthChecks,
  type ShellExecutor,
} from '../../src/core/health-rules.js';

// Helper: build a stub ShellExecutor
function makeShell(responses: Record<string, string>): ShellExecutor {
  return async (cmd, args) => {
    const key = [cmd, ...args].join(' ');
    // Exact match first
    if (key in responses) {
      const out = responses[key];
      return { stdout: out, stderr: '' };
    }
    // Prefix match (cmd + first arg)
    const prefix = `${cmd} ${args[0] ?? ''}`;
    for (const [k, v] of Object.entries(responses)) {
      if (k.startsWith(prefix)) {
        return { stdout: v, stderr: '' };
      }
    }
    return { stdout: '', stderr: '' };
  };
}

// Helper: shell that throws for certain commands (simulates failure)
function makeFailingShell(failOn: string[]): ShellExecutor {
  return async (cmd, args) => {
    const key = [cmd, ...args].join(' ');
    if (failOn.some((f) => key.includes(f))) {
      throw new Error(`Command failed: ${key}`);
    }
    return { stdout: '', stderr: '' };
  };
}

describe('computeScore', () => {
  it('returns 100 when no issues', () => {
    expect(computeScore([])).toBe(100);
  });

  it('deducts 10 per error', () => {
    const issues: HealthIssue[] = [
      { kind: 'test', severity: 'error', message: 'e1' },
      { kind: 'test', severity: 'error', message: 'e2' },
    ];
    expect(computeScore(issues)).toBe(80);
  });

  it('deducts 3 per warning', () => {
    const issues: HealthIssue[] = [
      { kind: 'test', severity: 'warning', message: 'w1' },
    ];
    expect(computeScore(issues)).toBe(97);
  });

  it('deducts 1 per info', () => {
    const issues: HealthIssue[] = [
      { kind: 'test', severity: 'info', message: 'i1' },
    ];
    expect(computeScore(issues)).toBe(99);
  });

  it('does not go below 0', () => {
    const issues: HealthIssue[] = Array.from({ length: 20 }, (_, i) => ({
      kind: 'test',
      severity: 'error' as const,
      message: `e${i}`,
    }));
    expect(computeScore(issues)).toBe(0);
  });
});

describe('parseEtime / isOlderThan2h', () => {
  it('parses mm:ss format', () => {
    expect(parseEtime('05:30')).toBe(330);
  });

  it('parses hh:mm:ss format', () => {
    expect(parseEtime('02:00:00')).toBe(7200);
  });

  it('parses dd-hh:mm:ss format', () => {
    expect(parseEtime('01-00:00:00')).toBe(86400);
  });

  it('isOlderThan2h: exactly 2h is NOT older', () => {
    expect(isOlderThan2h('02:00:00')).toBe(false);
  });

  it('isOlderThan2h: 2h1s IS older', () => {
    expect(isOlderThan2h('02:00:01')).toBe(true);
  });

  it('isOlderThan2h: short process is not older', () => {
    expect(isOlderThan2h('01:30')).toBe(false);
  });
});

describe('checkStaleBranches', () => {
  it('returns empty when ≤3 merged branches', async () => {
    const shell = makeShell({
      'git symbolic-ref refs/remotes/origin/HEAD --short': 'origin/main',
      'git branch --merged main': '  feature-a\n  feature-b\n',
    });
    const result = await checkStaleBranches('/repo', shell);
    expect(result).toHaveLength(0);
  });

  it('returns issue when >3 merged branches', async () => {
    const shell = makeShell({
      'git symbolic-ref refs/remotes/origin/HEAD --short': 'origin/main',
      'git branch --merged main': '  a\n  b\n  c\n  d\n  e\n',
    });
    const result = await checkStaleBranches('/repo', shell);
    expect(result).toHaveLength(1);
    expect(result[0].kind).toBe('stale_branches');
    expect(result[0].severity).toBe('info');
  });

  it('handles shell error gracefully', async () => {
    const shell = makeFailingShell(['branch']);
    const result = await checkStaleBranches('/repo', shell);
    expect(result).toHaveLength(0);
  });

  it('is safe with repo paths containing special chars', async () => {
    const shell = makeShell({
      'git symbolic-ref refs/remotes/origin/HEAD --short': 'origin/main',
      'git branch --merged main': '',
    });
    // Path with special chars — should not be injected into shell
    const result = await checkStaleBranches(
      '/repo/my project $(rm -rf /)',
      shell,
    );
    expect(result).toHaveLength(0);
  });
});

describe('checkLargeUncommitted', () => {
  it('returns empty when ≤20 changes', async () => {
    const lines = Array.from({ length: 10 }, (_, i) => ` M file${i}.ts`).join(
      '\n',
    );
    const shell = makeShell({ 'git status --porcelain': lines });
    const result = await checkLargeUncommitted('/repo', shell);
    expect(result).toHaveLength(0);
  });

  it('returns issue when >20 changes', async () => {
    const lines = Array.from({ length: 25 }, (_, i) => ` M file${i}.ts`).join(
      '\n',
    );
    const shell = makeShell({ 'git status --porcelain': lines });
    const result = await checkLargeUncommitted('/repo', shell);
    expect(result).toHaveLength(1);
    expect(result[0].kind).toBe('large_uncommitted');
    expect(result[0].severity).toBe('warning');
  });
});

describe('checkZombieDaemon', () => {
  it('returns empty when ≤2 daemon processes', async () => {
    const shell = makeShell({
      'pgrep -lf engram.*daemon|daemon.*engram':
        '123 engram daemon\n456 engram daemon',
    });
    const result = await checkZombieDaemon(shell);
    expect(result).toHaveLength(0);
  });

  it('returns issue when >2 daemon processes', async () => {
    const shell = makeShell({
      'pgrep -lf engram.*daemon|daemon.*engram':
        '1 engram daemon\n2 engram daemon\n3 engram daemon',
    });
    const result = await checkZombieDaemon(shell);
    expect(result).toHaveLength(1);
    expect(result[0].kind).toBe('zombie_daemon');
  });

  it('handles pgrep not finding anything (throws)', async () => {
    const shell = makeFailingShell(['pgrep']);
    const result = await checkZombieDaemon(shell);
    expect(result).toHaveLength(0);
  });
});

describe('checkEnvSecurity', () => {
  it('returns empty when no env files found', async () => {
    const shell = makeShell({
      'git ls-files --others --exclude-standard -z': '',
      'git ls-files -z': 'src/index.ts\0README.md\0',
    });
    const result = await checkEnvSecurity('/repo', shell);
    expect(result).toHaveLength(0);
  });

  it('returns empty when env file is gitignored (check-ignore exits 0)', async () => {
    // check-ignore exits 0 (success) = file is ignored = safe
    const shell: ShellExecutor = async (cmd, args) => {
      if (cmd === 'git' && args[0] === 'ls-files' && args[1] === '--others') {
        return { stdout: '.env\0', stderr: '' };
      }
      if (
        cmd === 'git' &&
        args[0] === 'ls-files' &&
        !args.includes('--others')
      ) {
        return { stdout: '', stderr: '' };
      }
      if (cmd === 'git' && args[0] === 'check-ignore') {
        return { stdout: '.env', stderr: '' }; // exits 0 = ignored
      }
      return { stdout: '', stderr: '' };
    };
    const result = await checkEnvSecurity('/repo', shell);
    expect(result).toHaveLength(0);
  });

  it('returns error when env file is NOT gitignored', async () => {
    // check-ignore exits nonzero = NOT ignored = exposed
    const shell: ShellExecutor = async (cmd, args) => {
      if (cmd === 'git' && args[0] === 'ls-files' && args[1] === '--others') {
        return { stdout: '.env\0', stderr: '' };
      }
      if (
        cmd === 'git' &&
        args[0] === 'ls-files' &&
        !args.includes('--others')
      ) {
        return { stdout: '', stderr: '' };
      }
      if (cmd === 'git' && args[0] === 'check-ignore') {
        throw new Error('not ignored'); // exits nonzero
      }
      return { stdout: '', stderr: '' };
    };
    const result = await checkEnvSecurity('/repo', shell);
    expect(result).toHaveLength(1);
    expect(result[0].kind).toBe('env_security');
    expect(result[0].severity).toBe('error');
  });
});

describe('checkZombieProcesses', () => {
  it('returns empty when no long-running node/python processes', async () => {
    const ps = [
      '  123  01:30 /usr/bin/zsh',
      '  456  00:05 node ./short-script.js',
    ].join('\n');
    const shell = makeShell({ 'ps axo pid,etime,command --no-headers': ps });
    const result = await checkZombieProcesses(shell);
    expect(result).toHaveLength(0);
  });

  it('returns issue for node process running >2h', async () => {
    const ps = ['  789  03:00:00 node /some/long-running/script.js'].join('\n');
    const shell = makeShell({ 'ps axo pid,etime,command --no-headers': ps });
    const result = await checkZombieProcesses(shell);
    expect(result).toHaveLength(1);
    expect(result[0].kind).toBe('zombie_processes');
  });

  it('ignores whitelisted processes', async () => {
    const ps = [
      '  111  05:00:00 node /path/to/vite/dist/node/cli.js',
      '  222  04:00:00 node next dev',
      '  333  06:00:00 node tsx watch src/index.ts',
    ].join('\n');
    const shell = makeShell({ 'ps axo pid,etime,command --no-headers': ps });
    const result = await checkZombieProcesses(shell);
    expect(result).toHaveLength(0);
  });

  it('ignores engram daemon processes', async () => {
    const ps = ['  100  10:00:00 node engram daemon dist/daemon.js'].join('\n');
    const shell = makeShell({ 'ps axo pid,etime,command --no-headers': ps });
    const result = await checkZombieProcesses(shell);
    expect(result).toHaveLength(0);
  });
});

describe('checkWorktreeHealth', () => {
  it('returns empty when no orphan worktrees', async () => {
    const porcelain = [
      'worktree /repo',
      'HEAD abc123',
      'branch refs/heads/main',
      '',
    ].join('\n');
    const shell = makeShell({ 'git worktree list --porcelain': porcelain });
    const result = await checkWorktreeHealth('/repo', shell);
    expect(result).toHaveLength(0);
  });

  it('returns warning for prunable worktrees', async () => {
    const porcelain = [
      'worktree /repo',
      'HEAD abc123',
      'branch refs/heads/main',
      '',
      'worktree /repo/linked-worktree',
      'HEAD def456',
      'branch refs/heads/feature',
      'prunable gitdir file points to non-existent location',
      '',
    ].join('\n');
    const shell = makeShell({ 'git worktree list --porcelain': porcelain });
    const result = await checkWorktreeHealth('/repo', shell);
    expect(result).toHaveLength(1);
    expect(result[0].kind).toBe('worktree_health');
    expect(result[0].severity).toBe('warning');
  });
});

describe('checkDependencySecurity', () => {
  // Use unique repo paths per test to avoid module-level cache interference

  it('returns empty when no vulnerabilities', async () => {
    const auditOutput = JSON.stringify({
      metadata: {
        vulnerabilities: { critical: 0, high: 0, moderate: 0, low: 0 },
      },
    });
    const shell: ShellExecutor = async (cmd, args) => {
      if (cmd === 'test') return { stdout: '', stderr: '' }; // package.json exists
      if (cmd === 'npm' && args[0] === 'audit')
        return { stdout: auditOutput, stderr: '' };
      return { stdout: '', stderr: '' };
    };
    const result = await checkDependencySecurity(['/repo/dep-clean'], shell);
    expect(result).toHaveLength(0);
  });

  it('returns error for critical vulnerabilities', async () => {
    const auditOutput = JSON.stringify({
      metadata: {
        vulnerabilities: { critical: 2, high: 1, moderate: 0, low: 3 },
      },
    });
    const shell: ShellExecutor = async (cmd, args) => {
      if (cmd === 'test') return { stdout: '', stderr: '' };
      if (cmd === 'npm' && args[0] === 'audit')
        return { stdout: auditOutput, stderr: '' };
      return { stdout: '', stderr: '' };
    };
    const result = await checkDependencySecurity(['/repo/dep-critical'], shell);
    expect(result).toHaveLength(1);
    expect(result[0].kind).toBe('dependency_security');
    expect(result[0].severity).toBe('error');
  });

  it('returns warning for moderate vulnerabilities', async () => {
    const auditOutput = JSON.stringify({
      metadata: {
        vulnerabilities: { critical: 0, high: 0, moderate: 3, low: 0 },
      },
    });
    const shell: ShellExecutor = async (cmd, args) => {
      if (cmd === 'test') return { stdout: '', stderr: '' };
      if (cmd === 'npm' && args[0] === 'audit')
        return { stdout: auditOutput, stderr: '' };
      return { stdout: '', stderr: '' };
    };
    const result = await checkDependencySecurity(['/repo/dep-moderate'], shell);
    expect(result).toHaveLength(1);
    expect(result[0].severity).toBe('warning');
  });

  it('skips repos without package.json', async () => {
    const shell: ShellExecutor = async (cmd) => {
      if (cmd === 'test') throw new Error('no package.json');
      return { stdout: '', stderr: '' };
    };
    const result = await checkDependencySecurity(['/repo/dep-no-pkg'], shell);
    expect(result).toHaveLength(0);
  });
});

describe('checkGitStash', () => {
  it('returns empty when ≤5 stashes', async () => {
    const stashes = Array.from(
      { length: 3 },
      (_, i) => `stash@{${i}}: WIP on main`,
    ).join('\n');
    const shell = makeShell({ 'git stash list': stashes });
    const result = await checkGitStash('/repo', shell);
    expect(result).toHaveLength(0);
  });

  it('returns issue when >5 stashes', async () => {
    const stashes = Array.from(
      { length: 8 },
      (_, i) => `stash@{${i}}: WIP on main`,
    ).join('\n');
    const shell = makeShell({ 'git stash list': stashes });
    const result = await checkGitStash('/repo', shell);
    expect(result).toHaveLength(1);
    expect(result[0].kind).toBe('git_stash');
    expect(result[0].severity).toBe('info');
  });
});

describe('checkBranchDivergence', () => {
  it('returns empty when in sync', async () => {
    const shell = makeShell({
      'git rev-list --left-right --count HEAD...@{u}': '2\t3',
    });
    const result = await checkBranchDivergence('/repo', shell);
    expect(result).toHaveLength(0);
  });

  it('returns warning when >20 commits behind', async () => {
    const shell = makeShell({
      'git rev-list --left-right --count HEAD...@{u}': '0\t25',
    });
    const result = await checkBranchDivergence('/repo', shell);
    expect(result).toHaveLength(1);
    expect(result[0].kind).toBe('branch_divergence');
    expect(result[0].severity).toBe('warning');
  });

  it('returns info when >50 commits ahead', async () => {
    const shell = makeShell({
      'git rev-list --left-right --count HEAD...@{u}': '55\t0',
    });
    const result = await checkBranchDivergence('/repo', shell);
    expect(result).toHaveLength(1);
    expect(result[0].severity).toBe('info');
  });

  it('handles no upstream gracefully', async () => {
    const shell = makeFailingShell(['rev-list']);
    const result = await checkBranchDivergence('/repo', shell);
    expect(result).toHaveLength(0);
  });
});

describe('runAllHealthChecks', () => {
  let db: Database;

  beforeEach(() => {
    db = new Database(':memory:');
  });

  afterEach(() => {
    db.close();
  });

  it('returns score 100 when no issues', async () => {
    // Shell that returns empty / benign output for all commands
    const shell: ShellExecutor = async () => ({ stdout: '', stderr: '' });
    const result = await runAllHealthChecks(db, { force: true, shell });
    expect(result.score).toBe(100);
    expect(result.issues).toHaveLength(0);
    expect(result.checkedAt).toMatch(/^\d{4}-\d{2}-\d{2}T/);
  });

  it('uses cached result within TTL', async () => {
    let callCount = 0;
    const shell: ShellExecutor = async () => {
      callCount++;
      return { stdout: '', stderr: '' };
    };
    // First call
    await runAllHealthChecks(db, { force: true, shell });
    const firstCallCount = callCount;

    // Second call (should use cache)
    await runAllHealthChecks(db, { force: false, shell });
    expect(callCount).toBe(firstCallCount); // no additional calls
  });

  it('bypasses cache when force: true', async () => {
    let callCount = 0;
    const shell: ShellExecutor = async () => {
      callCount++;
      return { stdout: '', stderr: '' };
    };
    await runAllHealthChecks(db, { force: true, shell });
    const firstCount = callCount;

    await runAllHealthChecks(db, { force: true, shell });
    expect(callCount).toBeGreaterThan(firstCount); // called again
  });

  it('returns HealthCheckResult shape', async () => {
    const shell: ShellExecutor = async () => ({ stdout: '', stderr: '' });
    const result = await runAllHealthChecks(db, { force: true, shell });
    expect(result).toHaveProperty('issues');
    expect(result).toHaveProperty('score');
    expect(result).toHaveProperty('checkedAt');
    expect(Array.isArray(result.issues)).toBe(true);
    expect(typeof result.score).toBe('number');
  });

  it('aggregates issues from multiple repos', async () => {
    // Seed two repos in git_repos
    const raw = db.getRawDb();
    raw
      .prepare(`
      INSERT INTO git_repos (path, name, branch, dirty_count, probed_at)
      VALUES (?, ?, 'main', 0, ?)
    `)
      .run('/repo/alpha', 'alpha', new Date().toISOString());
    raw
      .prepare(`
      INSERT INTO git_repos (path, name, branch, dirty_count, probed_at)
      VALUES (?, ?, 'main', 0, ?)
    `)
      .run('/repo/beta', 'beta', new Date().toISOString());

    // Shell that reports >20 uncommitted changes for each repo
    const shell: ShellExecutor = async (cmd, args) => {
      if (cmd === 'git' && args[0] === 'status') {
        const lines = Array.from(
          { length: 25 },
          (_, i) => ` M file${i}.ts`,
        ).join('\n');
        return { stdout: lines, stderr: '' };
      }
      return { stdout: '', stderr: '' };
    };

    const result = await runAllHealthChecks(db, {
      force: true,
      scope: 'global',
      shell,
    });
    // Should have at least 2 large_uncommitted issues (one per repo)
    const uncommitted = result.issues.filter(
      (i) => i.kind === 'large_uncommitted',
    );
    expect(uncommitted.length).toBeGreaterThanOrEqual(2);
  });
});
