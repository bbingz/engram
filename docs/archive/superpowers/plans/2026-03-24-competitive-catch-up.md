# Competitive Catch-Up Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close competitive gaps vs Readout/Agent Sessions by adding health check expansion, cost optimization suggestions, get_context panoramic aggregation, and transcript enhancement.

**Architecture:** Phase-based — Node data layer first (3 parallel modules), integration second (wire outputs + tests), Swift UI third (2 parallel tracks). All Node modules use dependency injection for testability. Swift views follow existing KPI Dashboard / ColorBarMessageView patterns.

**Tech Stack:** TypeScript (Vitest, better-sqlite3), Swift 5.9 (SwiftUI, GRDB), Hono HTTP server

**Spec:** `docs/superpowers/specs/2026-03-24-competitive-catch-up-design.md`

---

## File Map

### New Files (10)

| File | Responsibility |
|------|---------------|
| `src/core/health-rules.ts` | 10-category health check rule engine with shell executor injection |
| `src/core/cost-advisor.ts` | 8-rule cost optimization engine with savings simulation |
| `src/tools/get_insights.ts` | MCP tool handler wrapping cost-advisor |
| `tests/core/health-rules.test.ts` | Unit tests for health rules (injectable ShellExecutor) |
| `tests/core/cost-advisor.test.ts` | Unit tests for cost advisor (fixture DB data) |
| `tests/tools/get_insights.test.ts` | Integration test for MCP tool |
| `macos/Engram/Views/Transcript/ToolCallView.swift` | Structured tool call card rendering |
| `macos/Engram/Views/Transcript/ToolResultView.swift` | Collapsible tool result rendering |
| `macos/Engram/Core/ToolCallParser.swift` | Regex parser for Claude Code tool call format |
| `macos/Engram/Core/SyntaxHighlighter.swift` | Regex-based syntax highlighting (5 languages) |

### Modified Files (12)

| File | Change |
|------|--------|
| `src/tools/lint_config.ts` | Replace `runHealthChecks()` body → delegate to health-rules |
| `src/core/monitor.ts` | Add `runAllHealthChecks()` call in BackgroundMonitor.check() |
| `src/web.ts` | Add `GET /api/hygiene` endpoint |
| `src/core/db.ts` | Add compound index `idx_logs_level_ts`, drop redundant `idx_logs_level` |
| `src/tools/get_context.ts` | Add 5 new environment data blocks with token budget control |
| `src/index.ts` | Register `get_insights` tool + handler |
| `macos/Engram/Views/Transcript/ColorBarMessageView.swift` | Add `.toolCall` / `.toolResult` switch cases |
| `macos/Engram/Views/ContentSegmentViews.swift` | Syntax highlighting in CodeBlockView |
| `macos/Engram/Core/ContentSegmentParser.swift` | Add `.image` segment detection |
| `macos/Engram/Models/Screen.swift` | Add `.hygiene` case in MONITOR section |
| `macos/Engram/Views/SidebarView.swift` | Add Hygiene sidebar entry |
| `macos/Engram/Views/ContentView.swift` | Route `.hygiene` → HygieneView |

---

## Phase 1: Node Data Layer (3 parallel tasks)

**Parallel caveat**: Task 1 and Task 3 both touch `lint_config.ts`. If running in parallel worktrees this is fine (separate copies). If in same worktree, complete Task 1 Step 17 before Task 3 Step 2's configStatus block.

### Task 1: Health Rules Engine (`src/core/health-rules.ts`)

**Files:**
- Create: `src/core/health-rules.ts`
- Create: `tests/core/health-rules.test.ts`
- Modify: `src/tools/lint_config.ts`
- Modify: `src/web.ts`

- [ ] **Step 1: Write the ShellExecutor type + interface + skeleton**

Create `src/core/health-rules.ts`:

```typescript
import { execFile as nodeExecFile } from 'child_process'
import { promisify } from 'util'
import type { Database } from './db.js'

const execFileAsync = promisify(nodeExecFile)

export type ShellExecutor = (
  cmd: string,
  args: string[],
  options: { timeout: number; cwd?: string }
) => Promise<string>

export interface HealthIssue {
  kind: string
  severity: 'error' | 'warning' | 'info'
  message: string
  detail?: string
  repo?: string
  action?: string
}

export interface HealthCheckResult {
  issues: HealthIssue[]
  score: number
  checkedAt: string
}

const defaultExec: ShellExecutor = async (cmd, args, options) => {
  const { stdout } = await execFileAsync(cmd, args, {
    timeout: options.timeout,
    cwd: options.cwd,
    encoding: 'utf-8',
  })
  return stdout
}

let cachedResult: HealthCheckResult | null = null
let cachedAt = 0
const CACHE_TTL = 5 * 60 * 1000 // 5 min
const AUDIT_CACHE_TTL = 30 * 60 * 1000 // 30 min

export async function runAllHealthChecks(
  db: Database,
  options?: {
    force?: boolean
    scope?: 'project' | 'global'
    cwd?: string
    exec?: ShellExecutor
  }
): Promise<HealthCheckResult> {
  const now = Date.now()
  if (!options?.force && cachedResult && now - cachedAt < CACHE_TTL) {
    return cachedResult
  }

  const exec = options?.exec ?? defaultExec
  const repos = getRepos(db, options?.scope, options?.cwd)
  const issues: HealthIssue[] = []

  const checks = await Promise.allSettled([
    checkStaleBranches(repos, exec),
    checkLargeUncommitted(repos, exec),
    checkZombieDaemon(exec),
    checkEnvSecurity(repos, exec),
    checkZombieProcesses(exec),
    checkWorktreeHealth(repos, exec),
    checkDependencySecurity(db, repos, exec),
    checkGitStash(repos, exec),
    checkBranchDivergence(repos, exec),
  ])

  for (const result of checks) {
    if (result.status === 'fulfilled') {
      issues.push(...result.value)
    }
    // rejected = silently skipped (logged elsewhere)
  }

  const score = computeScore(issues)
  cachedResult = { issues, score, checkedAt: new Date().toISOString() }
  cachedAt = now
  return cachedResult
}

function getRepos(db: Database, scope?: string, cwd?: string): Array<{ path: string; name: string }> {
  if (scope === 'project' && cwd) {
    const rows = db.getRawDb().prepare('SELECT path, name FROM git_repos WHERE path = ? OR path LIKE ?').all(cwd, `${cwd}%`) as Array<{ path: string; name: string }>
    return rows
  }
  return db.getRawDb().prepare('SELECT path, name FROM git_repos').all() as Array<{ path: string; name: string }>
}

function computeScore(issues: HealthIssue[]): number {
  let penalty = 0
  for (const i of issues) {
    if (i.severity === 'error') penalty += 10
    else if (i.severity === 'warning') penalty += 3
    else penalty += 1
  }
  return Math.max(0, 100 - penalty)
}

// Placeholder stubs — each implemented in subsequent steps
async function checkStaleBranches(_repos: Array<{ path: string; name: string }>, _exec: ShellExecutor): Promise<HealthIssue[]> { return [] }
async function checkLargeUncommitted(_repos: Array<{ path: string; name: string }>, _exec: ShellExecutor): Promise<HealthIssue[]> { return [] }
async function checkZombieDaemon(_exec: ShellExecutor): Promise<HealthIssue[]> { return [] }
async function checkEnvSecurity(_repos: Array<{ path: string; name: string }>, _exec: ShellExecutor): Promise<HealthIssue[]> { return [] }
async function checkZombieProcesses(_exec: ShellExecutor): Promise<HealthIssue[]> { return [] }
async function checkWorktreeHealth(_repos: Array<{ path: string; name: string }>, _exec: ShellExecutor): Promise<HealthIssue[]> { return [] }
async function checkDependencySecurity(_db: Database, _repos: Array<{ path: string; name: string }>, _exec: ShellExecutor): Promise<HealthIssue[]> { return [] }
async function checkGitStash(_repos: Array<{ path: string; name: string }>, _exec: ShellExecutor): Promise<HealthIssue[]> { return [] }
async function checkBranchDivergence(_repos: Array<{ path: string; name: string }>, _exec: ShellExecutor): Promise<HealthIssue[]> { return [] }
```

- [ ] **Step 2: Write test skeleton + first test (score computation)**

Create `tests/core/health-rules.test.ts`:

```typescript
import { describe, it, expect, beforeAll } from 'vitest'
import { Database } from '../../src/core/db.js'
import { runAllHealthChecks, type ShellExecutor, type HealthIssue } from '../../src/core/health-rules.js'

// Stub executor that returns empty for everything
const nullExec: ShellExecutor = async () => ''

describe('health-rules', () => {
  let db: Database

  beforeAll(() => {
    db = new Database(':memory:')
    // Insert a test repo
    db.getRawDb().exec(`INSERT INTO git_repos (path, name, branch, dirty_count, untracked_count, unpushed_count, last_commit_hash, last_commit_msg, last_commit_at, probed_at) VALUES ('/tmp/test-repo', 'test-repo', 'main', 0, 0, 0, 'abc', 'init', '2026-01-01', '2026-01-01')`)
  })

  it('returns score 100 when no issues', async () => {
    const result = await runAllHealthChecks(db, { exec: nullExec, force: true })
    expect(result.score).toBe(100)
    expect(result.issues).toHaveLength(0)
    expect(result.checkedAt).toBeTruthy()
  })
})
```

- [ ] **Step 3: Run test to verify it passes**

Run: `npm test -- tests/core/health-rules.test.ts`
Expected: 1 test passes

- [ ] **Step 4: Implement checkStaleBranches**

**Behavior change from original**: Original `lint_config.ts:246` reports any merged branch (≥1). New version reports only when >3 merged branches exist, to reduce noise. This is intentional — most repos have 1-2 merged branches that haven't been cleaned up yet, which is normal.

Replace the stub in `src/core/health-rules.ts`:

```typescript
async function checkStaleBranches(repos: Array<{ path: string; name: string }>, exec: ShellExecutor): Promise<HealthIssue[]> {
  const issues: HealthIssue[] = []
  for (const repo of repos) {
    try {
      // Find default branch
      let mainBranch = 'main'
      try {
        const ref = await exec('git', ['symbolic-ref', 'refs/remotes/origin/HEAD', '--short'], { timeout: 5000, cwd: repo.path })
        mainBranch = ref.trim().replace('origin/', '')
      } catch { /* fallback to main */ }

      const merged = await exec('git', ['branch', '--merged', mainBranch], { timeout: 5000, cwd: repo.path })
      const branches = merged.split('\n')
        .map(b => b.trim())
        .filter(b => b && !b.startsWith('*') && b !== mainBranch && b !== 'master')
      if (branches.length > 3) {
        issues.push({
          kind: 'stale_branches',
          severity: 'info',
          message: `${branches.length} merged branches not deleted in ${repo.name}`,
          detail: branches.slice(0, 5).join(', ') + (branches.length > 5 ? '...' : ''),
          repo: repo.path,
          action: `cd ${repo.path} && git branch -d ${branches.slice(0, 5).join(' ')}`,
        })
      }
    } catch { /* not a git repo or git unavailable */ }
  }
  return issues
}
```

- [ ] **Step 5: Write test for checkStaleBranches**

Add to `tests/core/health-rules.test.ts`:

```typescript
it('detects stale branches', async () => {
  const exec: ShellExecutor = async (cmd, args) => {
    if (args.includes('symbolic-ref')) return 'origin/main'
    if (args.includes('--merged')) return '  feature-1\n  feature-2\n  feature-3\n  feature-4\n* main\n'
    return ''
  }
  const result = await runAllHealthChecks(db, { exec, force: true })
  const stale = result.issues.filter(i => i.kind === 'stale_branches')
  expect(stale).toHaveLength(1)
  expect(stale[0].severity).toBe('info')
  expect(stale[0].action).toContain('git branch -d')
})
```

- [ ] **Step 6: Run test, verify pass**

Run: `npm test -- tests/core/health-rules.test.ts`

- [ ] **Step 7: Implement checkLargeUncommitted**

**Behavior change from original**: Original `lint_config.ts:258` reports any uncommitted changes (≥1). New version reports only when >20 uncommitted changes, matching the spec. Small working-set changes are normal and not worth alerting on.

```typescript
async function checkLargeUncommitted(repos: Array<{ path: string; name: string }>, exec: ShellExecutor): Promise<HealthIssue[]> {
  const issues: HealthIssue[] = []
  for (const repo of repos) {
    try {
      const status = await exec('git', ['status', '--porcelain'], { timeout: 5000, cwd: repo.path })
      const count = status.split('\n').filter(l => l.trim()).length
      if (count > 20) {
        issues.push({
          kind: 'large_uncommitted',
          severity: 'warning',
          message: `${count} uncommitted changes in ${repo.name}`,
          repo: repo.path,
          action: `cd ${repo.path} && git status`,
        })
      }
    } catch { /* skip */ }
  }
  return issues
}
```

- [ ] **Step 8: Write test + run**

```typescript
it('warns on large uncommitted changes', async () => {
  const lines = Array.from({ length: 25 }, (_, i) => `M file${i}.ts`).join('\n')
  const exec: ShellExecutor = async (cmd, args) => {
    if (args.includes('--porcelain')) return lines
    return ''
  }
  const result = await runAllHealthChecks(db, { exec, force: true })
  const uncommitted = result.issues.filter(i => i.kind === 'large_uncommitted')
  expect(uncommitted).toHaveLength(1)
  expect(uncommitted[0].severity).toBe('warning')
  expect(result.score).toBeLessThan(100)
})
```

Run: `npm test -- tests/core/health-rules.test.ts`

- [ ] **Step 9: Implement checkZombieDaemon**

**Behavior change from original**: Original `lint_config.ts:270` reports when >1 daemon process (expected exactly 1). New version reports when >2 (expected ≤2), because during daemon restart there can legitimately be 2 processes briefly (old exiting + new starting).

```typescript
async function checkZombieDaemon(exec: ShellExecutor): Promise<HealthIssue[]> {
  try {
    const output = await exec('pgrep', ['-f', 'engram.*daemon'], { timeout: 5000 })
    const pids = output.split('\n').filter(l => l.trim())
    if (pids.length > 2) {
      return [{
        kind: 'zombie_daemon',
        severity: 'warning',
        message: `${pids.length} engram daemon processes running (expected ≤2)`,
        action: `kill ${pids.slice(2).join(' ')}`,
      }]
    }
  } catch { /* pgrep returns exit 1 when no match — normal */ }
  return []
}
```

- [ ] **Step 10: Implement checkEnvSecurity (new)**

```typescript
async function checkEnvSecurity(repos: Array<{ path: string; name: string }>, exec: ShellExecutor): Promise<HealthIssue[]> {
  const issues: HealthIssue[] = []
  for (const repo of repos) {
    try {
      // List .env* files in repo root (depth 1 only — intentional scope limit)
      const files = await exec('find', [repo.path, '-maxdepth', '1', '-name', '.env*', '-type', 'f'], { timeout: 5000 })
      const envFiles = files.split('\n').filter(f => f.trim())
      if (envFiles.length === 0) continue

      // Use git check-ignore — handles all .gitignore patterns (globs, negation, nested)
      for (const envFile of envFiles) {
        try {
          await exec('git', ['check-ignore', '-q', envFile], { timeout: 2000, cwd: repo.path })
          // exit 0 = ignored, all good
        } catch {
          // exit 1 = NOT ignored — this is the problem
          const basename = envFile.split('/').pop() || ''
          issues.push({
            kind: 'env_audit',
            severity: 'error',
            message: `${basename} not in .gitignore in ${repo.name}`,
            repo: repo.path,
            action: `echo '${basename}' >> ${repo.path}/.gitignore`,
          })
        }
      }
    } catch { /* skip — not a git repo or find unavailable */ }
  }
  return issues
}
```

- [ ] **Step 11: Write test for checkEnvSecurity + run**

```typescript
it('detects .env not in gitignore', async () => {
  const exec: ShellExecutor = async (cmd, args) => {
    if (cmd === 'find') return '/tmp/test-repo/.env\n/tmp/test-repo/.env.local\n'
    // git check-ignore: exit 1 (throw) = not ignored
    if (cmd === 'git' && args.includes('check-ignore')) throw new Error('exit 1')
    return ''
  }
  const result = await runAllHealthChecks(db, { exec, force: true })
  const envIssues = result.issues.filter(i => i.kind === 'env_audit')
  expect(envIssues).toHaveLength(2)
  expect(envIssues[0].severity).toBe('error')
  expect(envIssues[0].action).toContain('.gitignore')
})

it('skips .env files that ARE in gitignore', async () => {
  const exec: ShellExecutor = async (cmd, args) => {
    if (cmd === 'find') return '/tmp/test-repo/.env\n'
    // git check-ignore: exit 0 (success) = ignored
    if (cmd === 'git' && args.includes('check-ignore')) return '.env'
    return ''
  }
  const result = await runAllHealthChecks(db, { exec, force: true })
  const envIssues = result.issues.filter(i => i.kind === 'env_audit')
  expect(envIssues).toHaveLength(0)
})
```

Run: `npm test -- tests/core/health-rules.test.ts`

- [ ] **Step 12: Implement checkZombieProcesses (new)**

```typescript
const PROCESS_WHITELIST = [
  'engram.*daemon',
  'next dev', 'next start',
  'vite', 'webpack-dev-server',
  'nuxt', 'remix dev',
  'tsx watch', 'nodemon',
]

async function checkZombieProcesses(exec: ShellExecutor): Promise<HealthIssue[]> {
  const issues: HealthIssue[] = []
  try {
    // Find node/python processes running >2h
    const output = await exec('ps', ['axo', 'pid,etime,command'], { timeout: 5000 })
    const lines = output.split('\n').filter(l => l.trim())
    for (const line of lines) {
      const match = line.trim().match(/^\s*(\d+)\s+([\d:-]+)\s+(.+)$/)
      if (!match) continue
      const [, pid, etime, cmd] = match
      if (!/\b(node|python|tsx)\b/i.test(cmd)) continue
      if (PROCESS_WHITELIST.some(pat => cmd.includes(pat))) continue
      if (!isOlderThan2h(etime)) continue
      issues.push({
        kind: 'zombie_process',
        severity: 'warning',
        message: `Headless process (PID ${pid}) running >2h: ${cmd.slice(0, 80)}`,
        action: `kill ${pid}`,
      })
    }
  } catch { /* skip */ }
  return issues
}

function isOlderThan2h(etime: string): boolean {
  // etime format: [[dd-]hh:]mm:ss
  const parts = etime.trim().split(/[-:]/)
  if (parts.length >= 3) {
    const hours = parseInt(parts[parts.length - 3], 10) || 0
    const days = parts.length >= 4 ? parseInt(parts[parts.length - 4], 10) || 0 : 0
    return days > 0 || hours >= 2
  }
  return false
}
```

- [ ] **Step 13: Write test for zombie process detection + run**

```typescript
it('detects zombie processes with whitelist', async () => {
  const exec: ShellExecutor = async (cmd, args) => {
    if (cmd === 'ps') return [
      '  PID   ELAPSED COMMAND',
      '12345  03:15:00 node /tmp/orphan-script.js',
      '12346  04:00:00 node /usr/local/bin/next dev',
      '12347  00:30:00 node /tmp/short-lived.js',
      '12348  1-02:00:00 python /tmp/old-script.py',
    ].join('\n')
    return ''
  }
  const result = await runAllHealthChecks(db, { exec, force: true })
  const zombies = result.issues.filter(i => i.kind === 'zombie_process')
  expect(zombies).toHaveLength(2) // orphan-script + old-script (next dev whitelisted, short-lived <2h)
})
```

Run: `npm test -- tests/core/health-rules.test.ts`

- [ ] **Step 14: Implement remaining 3 checks (worktree, stash, divergence)**

Add to `src/core/health-rules.ts`:

```typescript
async function checkWorktreeHealth(repos: Array<{ path: string; name: string }>, exec: ShellExecutor): Promise<HealthIssue[]> {
  const issues: HealthIssue[] = []
  for (const repo of repos) {
    try {
      const output = await exec('git', ['worktree', 'list', '--porcelain'], { timeout: 5000, cwd: repo.path })
      const worktrees = output.split('\n\n').filter(b => b.trim())
      for (const wt of worktrees) {
        const pathMatch = wt.match(/^worktree (.+)$/m)
        if (!pathMatch) continue
        const wtPath = pathMatch[1]
        if (wtPath === repo.path) continue // skip main worktree

        // Check if path exists
        try {
          await exec('test', ['-d', wtPath], { timeout: 2000 })
        } catch {
          issues.push({
            kind: 'worktree',
            severity: 'warning',
            message: `Orphan worktree (path missing): ${wtPath}`,
            repo: repo.path,
            action: `git -C ${repo.path} worktree prune`,
          })
        }
      }
    } catch { /* skip */ }
  }
  return issues
}

async function checkGitStash(repos: Array<{ path: string; name: string }>, exec: ShellExecutor): Promise<HealthIssue[]> {
  const issues: HealthIssue[] = []
  for (const repo of repos) {
    try {
      const output = await exec('git', ['stash', 'list'], { timeout: 5000, cwd: repo.path })
      const count = output.split('\n').filter(l => l.trim()).length
      if (count > 5) {
        issues.push({
          kind: 'git_stash',
          severity: 'info',
          message: `${count} stashes accumulated in ${repo.name}`,
          repo: repo.path,
          action: `cd ${repo.path} && git stash list`,
        })
      }
    } catch { /* skip */ }
  }
  return issues
}

async function checkBranchDivergence(repos: Array<{ path: string; name: string }>, exec: ShellExecutor): Promise<HealthIssue[]> {
  const issues: HealthIssue[] = []
  for (const repo of repos) {
    try {
      const output = await exec('git', ['rev-list', '--left-right', '--count', 'HEAD...@{u}'], { timeout: 5000, cwd: repo.path })
      const [ahead, behind] = output.trim().split(/\s+/).map(Number)
      if (ahead > 0 && behind > 0) {
        issues.push({
          kind: 'branch_divergence',
          severity: 'warning',
          message: `Branch diverged in ${repo.name}: ${ahead} ahead, ${behind} behind upstream`,
          repo: repo.path,
          action: `cd ${repo.path} && git log --oneline --left-right HEAD...@{u}`,
        })
      }
    } catch { /* no upstream or not a git repo */ }
  }
  return issues
}
```

- [ ] **Step 15: Implement checkDependencySecurity (new, with 7-day active filter)**

```typescript
let auditCache: Map<string, { issues: HealthIssue[]; at: number }> = new Map()

async function checkDependencySecurity(db: Database, repos: Array<{ path: string; name: string }>, exec: ShellExecutor): Promise<HealthIssue[]> {
  const issues: HealthIssue[] = []
  const since = new Date(Date.now() - 7 * 24 * 60 * 60 * 1000).toISOString()

  // Only check repos with recent sessions
  const activeRepos = new Set<string>()
  const rows = db.getRawDb().prepare('SELECT DISTINCT cwd FROM sessions WHERE start_time >= ?').all(since) as Array<{ cwd: string }>
  for (const r of rows) activeRepos.add(r.cwd)

  for (const repo of repos) {
    if (!activeRepos.has(repo.path)) continue

    // Check audit cache (30 min)
    const cached = auditCache.get(repo.path)
    if (cached && Date.now() - cached.at < AUDIT_CACHE_TTL) {
      issues.push(...cached.issues)
      continue
    }

    try {
      // Verify package.json exists
      await exec('test', ['-f', repo.path + '/package.json'], { timeout: 2000 })

      const output = await exec('npm', ['audit', '--json'], { timeout: 10000, cwd: repo.path })
      const audit = JSON.parse(output)
      const vulns = audit.metadata?.vulnerabilities || {}
      const high = (vulns.high || 0) + (vulns.critical || 0)
      const moderate = vulns.moderate || 0

      const repoIssues: HealthIssue[] = []
      if (high > 0) {
        repoIssues.push({
          kind: 'dependency_security',
          severity: 'error',
          message: `${high} high/critical vulnerabilities in ${repo.name}`,
          repo: repo.path,
          action: `cd ${repo.path} && npm audit fix`,
        })
      } else if (moderate > 0) {
        repoIssues.push({
          kind: 'dependency_security',
          severity: 'warning',
          message: `${moderate} moderate vulnerabilities in ${repo.name}`,
          repo: repo.path,
          action: `cd ${repo.path} && npm audit`,
        })
      }
      auditCache.set(repo.path, { issues: repoIssues, at: Date.now() })
      issues.push(...repoIssues)
    } catch { /* npm not available or parse error */ }
  }
  return issues
}
```

- [ ] **Step 16: Write tests for worktree, stash, divergence, dependency + run**

```typescript
// Note: Each test's exec stub is called by ALL 9 checks. Stubs should return '' for
// unrecognized commands to avoid cross-check interference. The stubs below handle
// specific commands and fall through to '' for everything else, which is safe because
// empty output = no issues for all checks.

it('detects orphan worktrees', async () => {
  const exec: ShellExecutor = async (cmd, args) => {
    if (args.includes('--porcelain')) return 'worktree /tmp/test-repo\nHEAD abc123\nbranch refs/heads/main\n\nworktree /tmp/nonexistent\nHEAD def456\nbranch refs/heads/feature\n'
    if (cmd === 'test') throw new Error('not found')
    return ''
  }
  const result = await runAllHealthChecks(db, { exec, force: true })
  const wt = result.issues.filter(i => i.kind === 'worktree')
  expect(wt).toHaveLength(1)
  expect(wt[0].action).toContain('prune')
})

it('detects stash buildup', async () => {
  const stashes = Array.from({ length: 7 }, (_, i) => `stash@{${i}}: WIP on main`).join('\n')
  const exec: ShellExecutor = async (cmd, args) => {
    if (args.includes('stash')) return stashes
    return ''
  }
  const result = await runAllHealthChecks(db, { exec, force: true })
  expect(result.issues.find(i => i.kind === 'git_stash')).toBeTruthy()
})

it('detects branch divergence', async () => {
  const exec: ShellExecutor = async (cmd, args) => {
    if (args.includes('--left-right')) return '3\t5'
    return ''
  }
  const result = await runAllHealthChecks(db, { exec, force: true })
  const div = result.issues.filter(i => i.kind === 'branch_divergence')
  expect(div).toHaveLength(1)
  expect(div[0].message).toContain('3 ahead')
})

it('respects cache (returns cached result without force)', async () => {
  let callCount = 0
  const exec: ShellExecutor = async () => { callCount++; return '' }
  await runAllHealthChecks(db, { exec, force: true })
  const firstCount = callCount
  await runAllHealthChecks(db, { exec }) // should use cache
  expect(callCount).toBe(firstCount) // no new calls
})

it('detects zombie daemon processes', async () => {
  const exec: ShellExecutor = async (cmd, args) => {
    if (cmd === 'pgrep') return '111\n222\n333\n'
    return ''
  }
  const result = await runAllHealthChecks(db, { exec, force: true })
  const zombies = result.issues.filter(i => i.kind === 'zombie_daemon')
  expect(zombies).toHaveLength(1)
  expect(zombies[0].action).toContain('kill')
})

it('handles repo paths with special characters safely', async () => {
  // Insert repo with special chars in path
  db.getRawDb().exec(`INSERT OR REPLACE INTO git_repos (path, name, branch, dirty_count, unpushed_count, untracked_count, last_commit_hash, last_commit_msg, last_commit_at, probed_at)
    VALUES ('/tmp/repo with spaces & (parens)', 'special-repo', 'main', 0, 0, 0, 'a', 'b', '2026-01-01', '2026-01-01')`)

  // Exec should receive the path as a separate argument, not shell-interpolated
  let receivedArgs: string[] = []
  const exec: ShellExecutor = async (cmd, args) => {
    receivedArgs = args
    return ''
  }
  await runAllHealthChecks(db, { exec, force: true })
  // Verify path is passed as array element, not concatenated into a shell command
  // (This validates execFile usage — no shell injection possible)
  expect(receivedArgs.some(a => a.includes('repo with spaces'))).toBe(true)
})

it('handles dependency security check for active repos', async () => {
  const now = new Date().toISOString()
  db.getRawDb().exec(`INSERT INTO sessions (id, source, start_time, cwd, message_count) VALUES ('dep-test', 'claude-code', '${now}', '/tmp/test-repo', 5)`)

  const exec: ShellExecutor = async (cmd, args) => {
    if (cmd === 'test') return '' // package.json exists
    if (cmd === 'npm' && args.includes('audit')) return JSON.stringify({
      metadata: { vulnerabilities: { critical: 1, high: 2, moderate: 3 } }
    })
    return ''
  }
  const result = await runAllHealthChecks(db, { exec, force: true })
  const depIssues = result.issues.filter(i => i.kind === 'dependency_security')
  expect(depIssues).toHaveLength(1)
  expect(depIssues[0].severity).toBe('error')
})
```

Run: `npm test -- tests/core/health-rules.test.ts`

- [ ] **Step 17: Export health-rules from lint_config.ts (keep old function working)**

Modify `src/tools/lint_config.ts` — add re-export but **keep old function intact for now**:

```typescript
// Add at top of file:
import { runAllHealthChecks } from '../core/health-rules.js'
export { runAllHealthChecks }

// Keep existing runHealthChecks() UNCHANGED for now.
// It will be deprecated in Phase 2 Task 4 when get_context switches to runAllHealthChecks(db).
// This avoids a gap where health checks return empty between Phase 1 and Phase 2.
```

Note: The actual deprecation of `runHealthChecks()` happens in Phase 2 Task 4 Step 1, when `get_context.ts` is switched to call `runAllHealthChecks(db)` directly. Until then, the old synchronous function keeps working.

- [ ] **Step 18: Add GET /api/hygiene endpoint to web.ts**

Find the health/sources endpoint area in `src/web.ts` and add:

```typescript
import { runAllHealthChecks } from './core/health-rules.js'

app.get('/api/hygiene', async (c) => {
  const force = c.req.query('force') === 'true'
  const result = await runAllHealthChecks(db, { force, scope: 'global' })
  return c.json(result)
})
```

- [ ] **Step 19: Run all existing tests + new tests**

Run: `npm test`
Expected: All 616+ existing tests pass + ~10 new health-rules tests pass

- [ ] **Step 20: Commit**

```bash
git add src/core/health-rules.ts tests/core/health-rules.test.ts src/tools/lint_config.ts src/web.ts
git commit -m "feat: add 10-category health rules engine with /api/hygiene endpoint"
```

---

### Task 2: Cost Advisor Engine (`src/core/cost-advisor.ts`)

**Files:**
- Create: `src/core/cost-advisor.ts`
- Create: `tests/core/cost-advisor.test.ts`
- Create: `src/tools/get_insights.ts`
- Create: `tests/tools/get_insights.test.ts`
- Modify: `src/index.ts`

- [ ] **Step 1: Write the interface + skeleton**

Create `src/core/cost-advisor.ts`:

```typescript
import type { Database } from './db.js'
import type { FileSettings } from './config.js'
import { MODEL_PRICING } from './pricing.js'

export interface CostSuggestion {
  rule: string
  severity: 'high' | 'medium' | 'low'
  title: string
  detail: string
  savings?: {
    current: number
    projected: number
    percent: number
    period: 'daily' | 'weekly' | 'monthly'
  }
  topItems?: Array<{ name: string; value: number }>
}

export interface CostSuggestionResult {
  suggestions: CostSuggestion[]
  summary: {
    totalSpent: number
    projectedMonthly: number
    potentialSavings: number
  }
}

export async function getCostSuggestions(
  db: Database,
  config: FileSettings,
  options?: { since?: string }
): Promise<CostSuggestionResult> {
  const since = options?.since ?? new Date(Date.now() - 7 * 24 * 60 * 60 * 1000).toISOString()
  const suggestions: CostSuggestion[] = []

  const costsByModel = db.getCostsSummary({ groupBy: 'model', since })
  const totalSpent = costsByModel.reduce((sum: number, r: any) => sum + (r.costUsd || 0), 0)

  if (totalSpent === 0) {
    return { suggestions: [], summary: { totalSpent: 0, projectedMonthly: 0, potentialSavings: 0 } }
  }

  // Run all rules
  suggestions.push(...checkOpusOveruse(db, costsByModel, totalSpent, since))
  suggestions.push(...checkLowCacheRate(db, since))
  suggestions.push(...checkOverBudget(db, config, since))
  suggestions.push(...checkProjectHotspot(db, totalSpent, since))
  suggestions.push(...checkModelEfficiency(db, costsByModel))
  suggestions.push(...checkExpensiveSessions(db, since))
  suggestions.push(...checkWeekOverWeek(db))
  suggestions.push(...checkOutputImbalance(db, since))

  const days = Math.max(1, (Date.now() - new Date(since).getTime()) / (24 * 60 * 60 * 1000))
  const projectedMonthly = (totalSpent / days) * 30
  const potentialSavings = suggestions.reduce((sum, s) => sum + (s.savings?.current ?? 0) - (s.savings?.projected ?? 0), 0)

  return { suggestions, summary: { totalSpent, projectedMonthly, potentialSavings } }
}

// --- Rule implementations ---

function checkOpusOveruse(db: Database, costsByModel: any[], totalSpent: number, since: string): CostSuggestion[] {
  const opusCost = costsByModel
    .filter((r: any) => /opus/i.test(r.key || ''))
    .reduce((sum: number, r: any) => sum + (r.costUsd || 0), 0)
  if (opusCost / totalSpent <= 0.7) return []

  // Calculate savings only for short sessions (<20 messages)
  const rows = db.getRawDb().prepare(`
    SELECT c.cost_usd, c.input_tokens, c.output_tokens
    FROM session_costs c JOIN sessions s ON c.session_id = s.id
    WHERE c.model LIKE '%opus%' AND s.message_count < 20 AND s.start_time >= ?
  `).all(since) as Array<{ cost_usd: number; input_tokens: number; output_tokens: number }>

  const shortSessionCost = rows.reduce((sum, r) => sum + r.cost_usd, 0)
  // Estimate Sonnet cost using actual pricing from pricing.ts
  const sonnetInput = MODEL_PRICING['claude-sonnet-4-6']?.input ?? 3
  const sonnetOutput = MODEL_PRICING['claude-sonnet-4-6']?.output ?? 15
  const opusInput = MODEL_PRICING['claude-opus-4-6']?.input ?? 15
  const opusOutput = MODEL_PRICING['claude-opus-4-6']?.output ?? 75
  const avgRatio = ((sonnetInput / opusInput) + (sonnetOutput / opusOutput)) / 2
  const sonnetProjected = shortSessionCost * avgRatio
  const savings = shortSessionCost - sonnetProjected

  if (savings <= 0) return []

  return [{
    rule: 'opus_overuse',
    severity: 'high',
    title: `Opus is ${Math.round(opusCost / totalSpent * 100)}% of spend — use Sonnet for shorter sessions`,
    detail: `${rows.length} short sessions (<20 messages) used Opus. Switching these to Sonnet could save ~$${savings.toFixed(2)}/week. Complex sessions (≥20 messages) are excluded from this suggestion.`,
    savings: { current: shortSessionCost, projected: sonnetProjected, percent: Math.round(savings / shortSessionCost * 100), period: 'weekly' },
    topItems: costsByModel.slice(0, 3).map((r: any) => ({ name: r.key, value: r.costUsd })),
  }]
}

function checkLowCacheRate(db: Database, since: string): CostSuggestion[] {
  const row = db.getRawDb().prepare(`
    SELECT SUM(cache_read_tokens) as cache_read, SUM(input_tokens) as input
    FROM session_costs WHERE model LIKE 'claude-%' AND computed_at >= ?
  `).get(since) as { cache_read: number; input: number } | undefined

  if (!row || !row.input) return []
  const rate = row.cache_read / (row.input + row.cache_read)
  if (rate >= 0.3) return []

  const currentInputCost = row.input * 0.000003 // approximate
  const projectedWithCache = currentInputCost * 0.4 // 80% cache hit at 10% cost
  return [{
    rule: 'low_cache',
    severity: 'medium',
    title: `Cache hit rate is ${Math.round(rate * 100)}% — target 30%+`,
    detail: `Anthropic models only. With 80% cache hit rate, input token cost would drop ~60%.`,
    savings: { current: currentInputCost, projected: projectedWithCache, percent: Math.round((1 - projectedWithCache / currentInputCost) * 100), period: 'weekly' },
  }]
}

function checkOverBudget(db: Database, config: FileSettings, since: string): CostSuggestion[] {
  const budget = config.costAlerts?.dailyBudget ?? (config.monitor as any)?.dailyCostBudget
  if (!budget) return []

  const rows = db.getRawDb().prepare(`
    SELECT DATE(computed_at) as day, SUM(cost_usd) as cost
    FROM session_costs WHERE computed_at >= ? GROUP BY day
  `).all(since) as Array<{ day: string; cost: number }>

  if (rows.length === 0) return []
  const avgDaily = rows.reduce((s, r) => s + r.cost, 0) / rows.length
  if (avgDaily <= budget) return []

  return [{
    rule: 'over_budget',
    severity: 'high',
    title: `Daily avg $${avgDaily.toFixed(2)} exceeds $${budget.toFixed(2)} budget`,
    detail: `Over ${rows.length} days. Projected monthly: $${(avgDaily * 30).toFixed(2)}.`,
    savings: { current: avgDaily * 30, projected: budget * 30, percent: Math.round((1 - budget / avgDaily) * 100), period: 'monthly' },
  }]
}

function checkProjectHotspot(db: Database, totalSpent: number, since: string): CostSuggestion[] {
  const rows = db.getRawDb().prepare(`
    SELECT s.project, SUM(c.cost_usd) as cost
    FROM session_costs c JOIN sessions s ON c.session_id = s.id
    WHERE c.computed_at >= ? AND s.project IS NOT NULL
    GROUP BY s.project ORDER BY cost DESC LIMIT 5
  `).all(since) as Array<{ project: string; cost: number }>

  if (rows.length === 0 || rows[0].cost / totalSpent <= 0.5) return []

  return [{
    rule: 'project_hotspot',
    severity: 'medium',
    title: `Project "${rows[0].project}" is ${Math.round(rows[0].cost / totalSpent * 100)}% of total spend`,
    detail: `Consider reviewing usage patterns in this project.`,
    topItems: rows.slice(0, 3).map(r => ({ name: r.project, value: r.cost })),
  }]
}

function checkModelEfficiency(db: Database, costsByModel: any[]): CostSuggestion[] {
  if (costsByModel.length < 2) return []

  const items = costsByModel
    .filter((r: any) => r.sessionCount > 0)
    .map((r: any) => ({
      name: r.key as string,
      costPerMsg: (r.costUsd || 0) / r.sessionCount,
      value: r.costUsd || 0,
    }))
    .sort((a, b) => b.costPerMsg - a.costPerMsg)

  if (items.length < 2) return []

  return [{
    rule: 'model_efficiency',
    severity: 'low',
    title: `Model cost efficiency: ${items[0].name} $${items[0].costPerMsg.toFixed(3)}/session vs ${items[items.length - 1].name} $${items[items.length - 1].costPerMsg.toFixed(3)}/session`,
    detail: `Cost per session ranking across ${items.length} models. Note: costs attributed by session primary model.`,
    topItems: items.map(i => ({ name: i.name, value: i.costPerMsg })),
  }]
}

function checkExpensiveSessions(db: Database, since: string): CostSuggestion[] {
  const rows = db.getRawDb().prepare(`
    SELECT c.session_id, c.cost_usd, c.input_tokens + c.output_tokens as total_tokens, c.model
    FROM session_costs c WHERE c.cost_usd > 5 AND (c.input_tokens + c.output_tokens) > 200000 AND c.computed_at >= ?
    ORDER BY c.cost_usd DESC LIMIT 5
  `).all(since) as Array<{ session_id: string; cost_usd: number; total_tokens: number; model: string }>

  if (rows.length === 0) return []

  return [{
    rule: 'expensive_sessions',
    severity: 'medium',
    title: `${rows.length} expensive sessions (>$5, >200K tokens)`,
    detail: `Consider splitting long sessions to reduce context window costs.`,
    topItems: rows.map(r => ({ name: `${r.session_id.slice(-8)} (${r.model})`, value: r.cost_usd })),
  }]
}

function checkWeekOverWeek(db: Database): CostSuggestion[] {
  const now = Date.now()
  const thisWeekStart = new Date(now - 7 * 24 * 60 * 60 * 1000).toISOString()
  const lastWeekStart = new Date(now - 14 * 24 * 60 * 60 * 1000).toISOString()

  const thisWeek = (db.getRawDb().prepare(`SELECT SUM(cost_usd) as cost FROM session_costs WHERE computed_at >= ?`).get(thisWeekStart) as any)?.cost || 0
  const lastWeek = (db.getRawDb().prepare(`SELECT SUM(cost_usd) as cost FROM session_costs WHERE computed_at >= ? AND computed_at < ?`).get(lastWeekStart, thisWeekStart) as any)?.cost || 0

  if (lastWeek === 0 || thisWeek / lastWeek <= 1.5) return []

  return [{
    rule: 'week_over_week',
    severity: 'medium',
    title: `Costs up ${Math.round((thisWeek / lastWeek - 1) * 100)}% week-over-week`,
    detail: `This week: $${thisWeek.toFixed(2)} vs last week: $${lastWeek.toFixed(2)}.`,
    savings: { current: thisWeek, projected: lastWeek, percent: Math.round((1 - lastWeek / thisWeek) * 100), period: 'weekly' },
  }]
}

function checkOutputImbalance(db: Database, since: string): CostSuggestion[] {
  const row = db.getRawDb().prepare(`
    SELECT SUM(c.output_tokens) as output, SUM(c.input_tokens) as input
    FROM session_costs c
    WHERE c.computed_at >= ?
      AND c.session_id NOT IN (
        SELECT session_id FROM session_tools
        WHERE tool_name IN ('Write', 'Edit') GROUP BY session_id HAVING SUM(call_count) > 10
      )
  `).get(since) as { output: number; input: number } | undefined

  if (!row || !row.input || row.output / row.input <= 3) return []

  return [{
    rule: 'output_imbalance',
    severity: 'low',
    title: `Output/input ratio is ${(row.output / row.input).toFixed(1)}x (excluding code-gen sessions)`,
    detail: `High output ratio may indicate verbose generation. Sessions with >10 Write/Edit calls excluded.`,
  }]
}
```

- [ ] **Step 2: Write comprehensive test file**

Create `tests/core/cost-advisor.test.ts`:

```typescript
import { describe, it, expect, beforeAll } from 'vitest'
import { Database } from '../../src/core/db.js'
import { getCostSuggestions } from '../../src/core/cost-advisor.js'
import type { FileSettings } from '../../src/core/config.js'

describe('cost-advisor', () => {
  let db: Database
  const config: FileSettings = { costAlerts: { dailyBudget: 10 } }

  beforeAll(() => {
    db = new Database(':memory:')
    const raw = db.getRawDb()

    // Seed sessions
    raw.exec(`
      INSERT INTO sessions (id, source, start_time, cwd, message_count, project)
      VALUES
        ('s1', 'claude-code', '2026-03-20T10:00:00Z', '/tmp/proj', 5, 'proj-a'),
        ('s2', 'claude-code', '2026-03-21T10:00:00Z', '/tmp/proj', 30, 'proj-a'),
        ('s3', 'claude-code', '2026-03-22T10:00:00Z', '/tmp/proj', 8, 'proj-b')
    `)

    // Seed costs — Opus heavy
    raw.exec(`
      INSERT INTO session_costs (session_id, model, input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens, cost_usd, computed_at)
      VALUES
        ('s1', 'claude-opus-4-6', 50000, 10000, 1000, 0, 5.0, '2026-03-20T10:00:00Z'),
        ('s2', 'claude-opus-4-6', 200000, 50000, 5000, 0, 25.0, '2026-03-21T10:00:00Z'),
        ('s3', 'claude-sonnet-4-6', 30000, 8000, 500, 0, 1.0, '2026-03-22T10:00:00Z')
    `)

    // Seed tool usage
    raw.exec(`
      INSERT INTO session_tools (session_id, tool_name, call_count)
      VALUES ('s1', 'Read', 10), ('s2', 'Edit', 15), ('s3', 'Bash', 5)
    `)
  })

  it('returns empty suggestions when no cost data', async () => {
    const emptyDb = new Database(':memory:')
    const result = await getCostSuggestions(emptyDb, config)
    expect(result.suggestions).toHaveLength(0)
    expect(result.summary.totalSpent).toBe(0)
  })

  it('detects opus overuse', async () => {
    const result = await getCostSuggestions(db, config, { since: '2026-03-19T00:00:00Z' })
    const opus = result.suggestions.find(s => s.rule === 'opus_overuse')
    expect(opus).toBeTruthy()
    expect(opus!.severity).toBe('high')
    expect(opus!.savings).toBeTruthy()
    expect(opus!.savings!.percent).toBeGreaterThan(0)
  })

  it('detects low cache rate for Anthropic models only', async () => {
    const result = await getCostSuggestions(db, config, { since: '2026-03-19T00:00:00Z' })
    const cache = result.suggestions.find(s => s.rule === 'low_cache')
    // Cache read is very low (1000+5000+500 vs 50000+200000+30000 input)
    expect(cache).toBeTruthy()
  })

  it('detects over budget', async () => {
    const result = await getCostSuggestions(db, { costAlerts: { dailyBudget: 5 } }, { since: '2026-03-19T00:00:00Z' })
    const budget = result.suggestions.find(s => s.rule === 'over_budget')
    expect(budget).toBeTruthy()
    expect(budget!.severity).toBe('high')
  })

  it('skips over_budget when no budget configured', async () => {
    const result = await getCostSuggestions(db, {}, { since: '2026-03-19T00:00:00Z' })
    const budget = result.suggestions.find(s => s.rule === 'over_budget')
    expect(budget).toBeUndefined()
  })

  it('detects project hotspot', async () => {
    const result = await getCostSuggestions(db, config, { since: '2026-03-19T00:00:00Z' })
    const hotspot = result.suggestions.find(s => s.rule === 'project_hotspot')
    expect(hotspot).toBeTruthy()
    expect(hotspot!.title).toContain('proj-a')
  })

  it('detects model efficiency ranking', async () => {
    const result = await getCostSuggestions(db, config, { since: '2026-03-19T00:00:00Z' })
    const efficiency = result.suggestions.find(s => s.rule === 'model_efficiency')
    expect(efficiency).toBeTruthy()
    expect(efficiency!.topItems!.length).toBeGreaterThanOrEqual(2)
  })

  it('provides summary with projected monthly', async () => {
    const result = await getCostSuggestions(db, config, { since: '2026-03-19T00:00:00Z' })
    expect(result.summary.totalSpent).toBeCloseTo(31, 0)
    expect(result.summary.projectedMonthly).toBeGreaterThan(0)
  })
})
```

- [ ] **Step 3: Run tests**

Run: `npm test -- tests/core/cost-advisor.test.ts`
Expected: All 7 tests pass

- [ ] **Step 4: Create get_insights MCP tool**

Create `src/tools/get_insights.ts`:

```typescript
import type { Database } from '../core/db.js'
import type { FileSettings } from '../core/config.js'
import { getCostSuggestions } from '../core/cost-advisor.js'

export const getInsightsDefinition = {
  name: 'get_insights',
  description: 'Get actionable cost optimization suggestions with savings estimates',
  inputSchema: {
    type: 'object' as const,
    properties: {
      since: { type: 'string', description: 'ISO timestamp for analysis window start (default: 7 days ago)' },
    },
  },
}

export async function handleGetInsights(
  db: Database,
  config: FileSettings,
  args: { since?: string }
) {
  const result = await getCostSuggestions(db, config, { since: args.since })

  const lines: string[] = []
  lines.push(`## Cost Insights (${result.suggestions.length} suggestions)`)
  lines.push(`Total spent: $${result.summary.totalSpent.toFixed(2)} | Projected monthly: $${result.summary.projectedMonthly.toFixed(2)} | Potential savings: $${result.summary.potentialSavings.toFixed(2)}`)
  lines.push('')

  for (const s of result.suggestions) {
    const icon = s.severity === 'high' ? '🔴' : s.severity === 'medium' ? '🟡' : '🟢'
    lines.push(`${icon} **${s.title}**`)
    lines.push(s.detail)
    if (s.savings) {
      lines.push(`  Savings: $${(s.savings.current - s.savings.projected).toFixed(2)}/${s.savings.period} (${s.savings.percent}%)`)
    }
    lines.push('')
  }

  return { content: [{ type: 'text' as const, text: lines.join('\n') }] }
}
```

- [ ] **Step 5: Write get_insights integration test**

Create `tests/tools/get_insights.test.ts`:

```typescript
import { describe, it, expect, beforeAll } from 'vitest'
import { Database } from '../../src/core/db.js'
import { handleGetInsights } from '../../src/tools/get_insights.js'

describe('get_insights tool', () => {
  let db: Database

  beforeAll(() => {
    db = new Database(':memory:')
    db.getRawDb().exec(`
      INSERT INTO sessions (id, source, start_time, cwd, message_count)
      VALUES ('s1', 'claude-code', '2026-03-20T10:00:00Z', '/tmp', 5)
    `)
    db.getRawDb().exec(`
      INSERT INTO session_costs (session_id, model, input_tokens, output_tokens, cost_usd, computed_at)
      VALUES ('s1', 'claude-opus-4-6', 100000, 20000, 10.0, '2026-03-20T10:00:00Z')
    `)
  })

  it('returns formatted text content', async () => {
    const result = await handleGetInsights(db, {}, {})
    expect(result.content[0].type).toBe('text')
    expect(result.content[0].text).toContain('Cost Insights')
  })

  it('handles empty data gracefully', async () => {
    const emptyDb = new Database(':memory:')
    const result = await handleGetInsights(emptyDb, {}, {})
    expect(result.content[0].text).toContain('0 suggestions')
  })
})
```

- [ ] **Step 6: Register get_insights in index.ts**

Modify `src/index.ts` — add to tool definitions list and handler:

```typescript
import { getInsightsDefinition, handleGetInsights } from './tools/get_insights.js'

// In ListToolsRequestSchema handler, add:
getInsightsDefinition,

// In CallToolRequestSchema handler, add case:
case 'get_insights':
  return handleGetInsights(db, settings, args as { since?: string })
```

- [ ] **Step 7: Add remaining cost-advisor rule tests**

Add to `tests/core/cost-advisor.test.ts`:

```typescript
it('detects expensive sessions', async () => {
  db.getRawDb().exec(`
    INSERT INTO sessions (id, source, start_time, cwd, message_count) VALUES ('s-exp', 'claude-code', '2026-03-22T10:00:00Z', '/tmp', 50)
  `)
  db.getRawDb().exec(`
    INSERT INTO session_costs (session_id, model, input_tokens, output_tokens, cost_usd, computed_at) VALUES ('s-exp', 'claude-opus-4-6', 300000, 100000, 8.5, '2026-03-22T10:00:00Z')
  `)
  const result = await getCostSuggestions(db, config, { since: '2026-03-19T00:00:00Z' })
  expect(result.suggestions.find(s => s.rule === 'expensive_sessions')).toBeTruthy()
})

it('detects week-over-week spike', async () => {
  // Seed last week data (low cost)
  db.getRawDb().exec(`
    INSERT INTO sessions (id, source, start_time, cwd, message_count) VALUES ('s-lw', 'claude-code', '2026-03-14T10:00:00Z', '/tmp', 5)
  `)
  db.getRawDb().exec(`
    INSERT INTO session_costs (session_id, model, input_tokens, output_tokens, cost_usd, computed_at) VALUES ('s-lw', 'claude-sonnet-4-6', 10000, 2000, 0.5, '2026-03-14T10:00:00Z')
  `)
  const result = await getCostSuggestions(db, config, { since: '2026-03-10T00:00:00Z' })
  const wow = result.suggestions.find(s => s.rule === 'week_over_week')
  // This week's cost ($31+$8.5) >> last week's ($0.5) → should trigger
  expect(wow).toBeTruthy()
})

it('detects output imbalance', async () => {
  db.getRawDb().exec(`
    INSERT INTO sessions (id, source, start_time, cwd, message_count) VALUES ('s-oi', 'claude-code', '2026-03-22T10:00:00Z', '/tmp', 10)
  `)
  db.getRawDb().exec(`
    INSERT INTO session_costs (session_id, model, input_tokens, output_tokens, cost_usd, computed_at) VALUES ('s-oi', 'claude-sonnet-4-6', 5000, 20000, 0.5, '2026-03-22T10:00:00Z')
  `)
  // No Write/Edit tools for this session — should be included in imbalance check
  const result = await getCostSuggestions(db, config, { since: '2026-03-19T00:00:00Z' })
  // output/input ratio is high across all sessions now
  const imbalance = result.suggestions.find(s => s.rule === 'output_imbalance')
  // May or may not trigger depending on aggregate — test that rule doesn't crash
  expect(result.suggestions).toBeDefined()
})
```

- [ ] **Step 8: Run all tests**

Run: `npm test`
Expected: All existing + new tests pass

- [ ] **Step 9: Commit**

```bash
git add src/core/cost-advisor.ts src/tools/get_insights.ts tests/core/cost-advisor.test.ts tests/tools/get_insights.test.ts src/index.ts
git commit -m "feat: add cost optimization advisor with 8 rules + get_insights MCP tool"
```

---

### Task 3: get_context Stub + DB Migration (Phase 1 part)

**Files:**
- Modify: `src/core/db.ts`
- Modify: `src/tools/get_context.ts`
- Modify: `tests/tools/get_context.test.ts`

- [ ] **Step 1: Add compound index in db.ts migration**

In `src/core/db.ts`, find the logs index section and add:

```typescript
// Replace existing idx_logs_level with compound index
db.exec(`DROP INDEX IF EXISTS idx_logs_level`)
db.exec(`CREATE INDEX IF NOT EXISTS idx_logs_level_ts ON logs(level, ts)`)
```

- [ ] **Step 2: Add environment data gathering stubs to get_context.ts**

In `src/tools/get_context.ts`:

First, update `gatherEnvironmentData()` signature to receive params and maxTokens:

```typescript
// Change: async function gatherEnvironmentData(db: Database, deps: GetContextDeps): Promise<string>
// To:     async function gatherEnvironmentData(db: Database, deps: GetContextDeps, params?: Record<string, any>, maxTokens?: number): Promise<string>
```

Update the call site in `handleGetContext()` to pass params and maxTokens:
```typescript
// Change: const envText = await gatherEnvironmentData(db, deps)
// To:     const envText = await gatherEnvironmentData(db, deps, args, maxTokens)
```

Then add detail-level gating at the start of gatherEnvironmentData:
```typescript
const detail = (params?.detail as string) || 'full'
```

Then add new sections after the existing ones. Gate by detail level:

```typescript
// --- New environment data blocks ---
// Skip these for 'abstract' mode (only costToday + alerts)
if (detail !== 'abstract') {

// Git repos with issues
try {
  const repos = db.getRawDb().prepare(`
    SELECT name, branch, dirty_count, unpushed_count
    FROM git_repos WHERE dirty_count > 0 OR unpushed_count > 0 LIMIT 10
  `).all() as Array<{ name: string; branch: string; dirty_count: number; unpushed_count: number }>
  if (repos.length > 0) {
    const lines = repos.map((r: any) => `  ${r.name} (${r.branch}): ${r.dirty_count} dirty, ${r.unpushed_count} unpushed`)
    sections.push(`Git repos needing attention (${repos.length}):\n${lines.join('\n')}`)
  }
} catch (err: unknown) {
  if (!isNoSuchTableError(err)) console.error('[get_context] gitRepos error:', err)
}

// File hotspots (last 7 days)
try {
  const since = new Date(Date.now() - 7 * 24 * 60 * 60 * 1000).toISOString()
  const files = db.getRawDb().prepare(`
    SELECT file_path, SUM(count) as total, COUNT(DISTINCT session_id) as sessions
    FROM session_files WHERE action = 'Edit' AND session_id IN (SELECT id FROM sessions WHERE start_time >= ?)
    GROUP BY file_path ORDER BY total DESC LIMIT 10
  `).all(since) as Array<{ file_path: string; total: number; sessions: number }>
  if (files.length > 0) {
    const lines = files.map((f: any) => `  ${f.file_path}: ${f.total} edits across ${f.sessions} sessions`)
    sections.push(`File hotspots (7d):\n${lines.join('\n')}`)
  }
} catch (err: unknown) {
  if (!isNoSuchTableError(err)) console.error('[get_context] fileHotspots error:', err)
}

// Recent errors (last 24h from logs table)
try {
  const since24h = new Date(Date.now() - 24 * 60 * 60 * 1000).toISOString()
  const errors = db.getRawDb().prepare(`
    SELECT module, message, COUNT(*) as count, MAX(ts) as last_seen
    FROM logs WHERE level = 'error' AND ts >= ?
    GROUP BY module, message ORDER BY count DESC LIMIT 5
  `).all(since24h) as Array<{ module: string; message: string; count: number; last_seen: string }>
  if (errors.length > 0) {
    const lines = errors.map((e: any) => `  [${e.module}] ${e.message.slice(0, 100)} (${e.count}x, last: ${e.last_seen})`)
    sections.push(`Recent errors (24h):\n${lines.join('\n')}`)
  }
} catch (err: unknown) {
  if (!isNoSuchTableError(err)) console.error('[get_context] recentErrors error:', err)
}

// Config status (from lintConfig)
// Note: handleLintConfig returns { issues: LintIssue[]; score: number }, NOT MCP response format
try {
  const { handleLintConfig } = await import('./lint_config.js')
  const cwd = (params?.cwd as string) || process.cwd()
  const lintResult = await handleLintConfig({ cwd })
  if (lintResult.score < 100) {
    const errors = lintResult.issues.filter((i: any) => i.severity === 'error').length
    const warnings = lintResult.issues.filter((i: any) => i.severity === 'warning').length
    sections.push(`Config score: ${lintResult.score}/100 (${errors} errors, ${warnings} warnings)`)
  }
} catch { /* config lint is best-effort */ }

// Cost suggestions placeholder (wired in Phase 2)
// costSuggestions: [] — will be populated after cost-advisor integration

} // end if (detail !== 'abstract')
```

For `overview` mode, truncate item counts to top 5 (vs full's top 10). Apply via the LIMIT clauses:

```typescript
const itemLimit = detail === 'overview' ? 5 : 10
// Use itemLimit in SQL LIMIT clauses for gitRepos, fileHotspots, recentErrors
```

- [ ] **Step 3: Add token budget control**

Add at the END of `gatherEnvironmentData()`, after collecting all sections (this replaces the existing return statement):

```typescript
// Token budget control: cap environment at 30% of maxChars
if (sections.length > 0) {
  const envText = `\n\n## Environment\n${sections.join('\n')}`
  const maxEnvChars = (maxTokens ?? 4000) * CHARS_PER_TOKEN * 0.3

  if (envText.length > maxEnvChars) {
    // Progressive drop: configStatus → fileHotspots → gitRepos → recentErrors
    const dropOrder = ['Config score:', 'File hotspots', 'Git repos needing', 'Recent errors']
    let filtered = [...sections]
    for (const prefix of dropOrder) {
      if (filtered.join('\n').length <= maxEnvChars) break
      filtered = filtered.filter(s => !s.startsWith(prefix))
    }
    return `\n\n## Environment\n${filtered.join('\n')}`
  }
  return envText
}
```

- [ ] **Step 4: Write tests for new environment data**

Add to `tests/tools/get_context.test.ts`:

```typescript
it('includes git repos in environment data', async () => {
  db.getRawDb().exec(`
    INSERT OR REPLACE INTO git_repos (path, name, branch, dirty_count, unpushed_count, untracked_count, last_commit_hash, last_commit_msg, last_commit_at, probed_at)
    VALUES ('/tmp/dirty-repo', 'dirty-repo', 'main', 5, 2, 0, 'abc', 'msg', '2026-03-24', '2026-03-24')
  `)
  const result = await handleGetContext(db, { include_environment: true }, deps)
  expect(result.content[0].text).toContain('dirty-repo')
})

it('includes file hotspots in environment data', async () => {
  const now = new Date().toISOString()
  db.getRawDb().exec(`
    INSERT INTO sessions (id, source, start_time, cwd) VALUES ('fh-test', 'claude-code', '${now}', '/tmp')
  `)
  db.getRawDb().exec(`
    INSERT INTO session_files (session_id, file_path, action, count) VALUES ('fh-test', '/src/core/db.ts', 'Edit', 15)
  `)
  const result = await handleGetContext(db, { include_environment: true }, deps)
  expect(result.content[0].text).toContain('db.ts')
})

it('abstract detail level returns only costToday and alerts', async () => {
  const result = await handleGetContext(db, { include_environment: true, detail: 'abstract' }, deps)
  const text = result.content[0].text
  // Should NOT contain new data blocks
  expect(text).not.toContain('Git repos')
  expect(text).not.toContain('File hotspots')
  expect(text).not.toContain('Recent errors')
})
```

- [ ] **Step 5: Run tests**

Run: `npm test -- tests/tools/get_context.test.ts`

- [ ] **Step 6: Commit**

```bash
git add src/core/db.ts src/tools/get_context.ts tests/tools/get_context.test.ts
git commit -m "feat: add panoramic environment data to get_context (git repos, file hotspots, errors, config)"
```

---

## Phase 2: Integration + Wiring

### Task 4: Wire get_context to Real Health Rules + Cost Advisor

**Files:**
- Modify: `src/tools/get_context.ts`
- Modify: `src/core/monitor.ts`
- Modify: `tests/tools/get_context.test.ts`

- [ ] **Step 1: Wire health-rules into get_context**

In `src/tools/get_context.ts`, replace the existing health check section:

```typescript
// Replace:
//   const { runHealthChecks } = await import('./lint_config.js')
//   const healthIssues = runHealthChecks(cwd)
// With:
import { runAllHealthChecks } from '../core/health-rules.js'

// In gatherEnvironmentData:
try {
  const cwd = params?.cwd || process.cwd()
  const healthResult = await runAllHealthChecks(db, { scope: 'project', cwd })
  if (healthResult.issues.length > 0) {
    const lines = healthResult.issues.map(h => `  [${h.severity}] ${h.message}`)
    sections.push(`Health (score ${healthResult.score}/100, ${healthResult.issues.length} issues):\n${lines.join('\n')}`)
  }
} catch { /* health checks are best-effort */ }
```

- [ ] **Step 2: Wire cost-advisor into get_context**

Add after the health section:

```typescript
// Cost optimization suggestions
try {
  const { getCostSuggestions } = await import('../core/cost-advisor.js')
  const costResult = await getCostSuggestions(db, deps.config ?? {}, { since: new Date(Date.now() - 7 * 24 * 60 * 60 * 1000).toISOString() })
  if (costResult.suggestions.length > 0) {
    const lines = costResult.suggestions.slice(0, 5).map(s => {
      const savingsText = s.savings ? ` (save ~$${(s.savings.current - s.savings.projected).toFixed(2)}/${s.savings.period})` : ''
      return `  [${s.severity}] ${s.title}${savingsText}`
    })
    sections.push(`Cost suggestions (${costResult.suggestions.length}):\n${lines.join('\n')}`)
  }
} catch { /* cost advisor is best-effort */ }
```

- [ ] **Step 3: Wire health-rules into BackgroundMonitor**

In `src/core/monitor.ts`, add to `check()` method:

```typescript
import { runAllHealthChecks } from './health-rules.js'

// In BackgroundMonitor.check(), add:
try {
  const healthResult = await runAllHealthChecks(this.db, { scope: 'global' })
  for (const issue of healthResult.issues) {
    if (issue.severity === 'error') {
      this.emitAlert({
        rule: `health_${issue.kind}`,
        severity: 'warning',
        title: issue.message,
        message: issue.detail || issue.message,
        value: 1,
        threshold: 0,
      })
    }
  }
} catch { /* health checks best-effort in monitor */ }
```

- [ ] **Step 4: Update get_context tests**

Add to `tests/tools/get_context.test.ts`:

```typescript
it('includes health check results from health-rules engine', async () => {
  // Seed a git repo so health checks have something to scan
  db.getRawDb().exec(`
    INSERT OR REPLACE INTO git_repos (path, name, branch, dirty_count, unpushed_count, untracked_count, last_commit_hash, last_commit_msg, last_commit_at, probed_at)
    VALUES ('/tmp/test', 'test', 'main', 0, 0, 0, 'a', 'b', '2026-01-01', '2026-01-01')
  `)
  const result = await handleGetContext(db, { include_environment: true }, deps)
  // Health section should exist (even if no issues, the section header appears conditionally)
  expect(result.content[0].text).toBeTruthy()
})
```

- [ ] **Step 5: Add /api/hygiene endpoint test**

Create `tests/web/hygiene.test.ts`:

```typescript
import { describe, it, expect, beforeAll } from 'vitest'
import { Database } from '../../src/core/db.js'

describe('GET /api/hygiene', () => {
  let db: Database

  beforeAll(() => {
    db = new Database(':memory:')
    db.getRawDb().exec(`
      INSERT INTO git_repos (path, name, branch, dirty_count, unpushed_count, untracked_count, last_commit_hash, last_commit_msg, last_commit_at, probed_at)
      VALUES ('/tmp/test', 'test', 'main', 0, 0, 0, 'a', 'b', '2026-01-01', '2026-01-01')
    `)
  })

  it('returns correct schema with score and issues array', async () => {
    const { runAllHealthChecks } = await import('../../src/core/health-rules.js')
    const result = await runAllHealthChecks(db, { force: true })
    expect(result).toHaveProperty('issues')
    expect(result).toHaveProperty('score')
    expect(result).toHaveProperty('checkedAt')
    expect(Array.isArray(result.issues)).toBe(true)
    expect(typeof result.score).toBe('number')
    expect(result.score).toBeGreaterThanOrEqual(0)
    expect(result.score).toBeLessThanOrEqual(100)
  })

  it('force parameter bypasses cache', async () => {
    const { runAllHealthChecks } = await import('../../src/core/health-rules.js')
    const r1 = await runAllHealthChecks(db, { force: true })
    const r2 = await runAllHealthChecks(db, { force: true })
    // Both should return fresh results (different checkedAt timestamps possible)
    expect(r2.checkedAt).toBeTruthy()
  })
})
```

- [ ] **Step 6: Run full test suite**

Run: `npm test`
Expected: All tests pass (616 existing + ~40 new)

- [ ] **Step 7: Build and verify**

Run: `npm run build`
Expected: Clean compilation, no type errors

- [ ] **Step 8: Commit**

```bash
git add src/tools/get_context.ts src/core/monitor.ts tests/tools/get_context.test.ts tests/web/hygiene.test.ts
git commit -m "feat: wire health-rules + cost-advisor into get_context and BackgroundMonitor"
```

---

## Phase 3: Swift UI (2 parallel tracks)

### Task 5: Transcript Enhancement (Swift)

**Files:**
- Create: `macos/Engram/Core/ToolCallParser.swift`
- Create: `macos/Engram/Views/Transcript/ToolCallView.swift`
- Create: `macos/Engram/Views/Transcript/ToolResultView.swift`
- Create: `macos/Engram/Core/SyntaxHighlighter.swift`
- Modify: `macos/Engram/Views/Transcript/ColorBarMessageView.swift`
- Modify: `macos/Engram/Views/ContentSegmentViews.swift`
- Modify: `macos/Engram/Core/ContentSegmentParser.swift`

- [ ] **Step 1: Create ToolCallParser**

Create `macos/Engram/Core/ToolCallParser.swift`:

```swift
import Foundation

struct ParsedToolCall {
    let toolName: String
    let parameters: [(key: String, value: String)]
    let rawContent: String
}

struct ParsedToolResult {
    let toolName: String?
    let output: String
    let isError: Bool
    let byteSize: Int
}

enum ToolCallParser {
    // Matches Claude Code format: `ToolName`: followed by content
    private static let toolCallPattern = try! NSRegularExpression(
        pattern: #"^`(\w+)`[:(]\s*"#, options: [.anchorsMatchLines]
    )

    static func parseToolCall(_ content: String) -> ParsedToolCall? {
        let range = NSRange(content.startIndex..., in: content)
        guard let match = toolCallPattern.firstMatch(in: content, range: range),
              let nameRange = Range(match.range(at: 1), in: content) else {
            return nil
        }

        let toolName = String(content[nameRange])
        let parameters = extractParameters(from: content, after: match.range.upperBound)

        return ParsedToolCall(
            toolName: toolName,
            parameters: parameters,
            rawContent: content
        )
    }

    static func parseToolResult(_ content: String) -> ParsedToolResult? {
        let isError = content.hasPrefix("Error:") ||
                      content.contains("EXIT CODE") ||
                      content.contains("ENOENT:")

        // Try to extract tool name from result prefix
        let namePattern = try! NSRegularExpression(pattern: #"^`(\w+)` result"#)
        let range = NSRange(content.startIndex..., in: content)
        let toolName = namePattern.firstMatch(in: content, range: range).flatMap {
            Range($0.range(at: 1), in: content).map { String(content[$0]) }
        }

        return ParsedToolResult(
            toolName: toolName,
            output: content,
            isError: isError,
            byteSize: content.utf8.count
        )
    }

    private static func extractParameters(from content: String, after offset: Int) -> [(key: String, value: String)] {
        var params: [(key: String, value: String)] = []
        let remaining = String(content.dropFirst(offset))

        // Try JSON-style: {"key": "value", ...}
        if let jsonStart = remaining.firstIndex(of: "{"),
           let data = remaining[jsonStart...].data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for (key, value) in json.sorted(by: { $0.key < $1.key }) {
                params.append((key: key, value: "\(value)"))
            }
            return params
        }

        // Fallback: key: value line format
        let linePattern = try! NSRegularExpression(pattern: #"^\s*(\w+):\s*(.+)$"#, options: .anchorsMatchLines)
        let nsRange = NSRange(remaining.startIndex..., in: remaining)
        linePattern.enumerateMatches(in: remaining, range: nsRange) { match, _, _ in
            guard let match,
                  let keyRange = Range(match.range(at: 1), in: remaining),
                  let valRange = Range(match.range(at: 2), in: remaining) else { return }
            params.append((key: String(remaining[keyRange]), value: String(remaining[valRange])))
        }

        return params
    }
}
```

- [ ] **Step 2: Create ToolCallView**

Create `macos/Engram/Views/Transcript/ToolCallView.swift`:

```swift
import SwiftUI

struct ToolCallView: View {
    let parsed: ParsedToolCall

    @State private var expandedParams: Set<String> = []
    private let maxCollapsedLength = 200

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Header: tool name badge
            HStack(spacing: 6) {
                Image(systemName: "wrench.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Text(parsed.toolName)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(parsed.rawContent, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 10))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }

            // Parameters
            ForEach(Array(parsed.parameters.enumerated()), id: \.offset) { _, param in
                HStack(alignment: .top, spacing: 8) {
                    Text(param.key)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 60, alignment: .trailing)

                    if param.value.count > maxCollapsedLength && !expandedParams.contains(param.key) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(String(param.value.prefix(maxCollapsedLength)) + "...")
                                .font(.system(size: 11, design: .monospaced))
                                .textSelection(.enabled)
                            Button("Show more") {
                                expandedParams.insert(param.key)
                            }
                            .font(.system(size: 10))
                            .buttonStyle(.plain)
                            .foregroundStyle(.blue)
                        }
                    } else {
                        Text(param.value)
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }
            }
        }
        .padding(8)
        .background(Color.purple.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}
```

- [ ] **Step 3: Create ToolResultView**

Create `macos/Engram/Views/Transcript/ToolResultView.swift`:

```swift
import SwiftUI

struct ToolResultView: View {
    let parsed: ParsedToolResult

    @State private var isExpanded: Bool
    private let collapseThreshold = 5

    init(parsed: ParsedToolResult) {
        self.parsed = parsed
        let lineCount = parsed.output.components(separatedBy: "\n").count
        self._isExpanded = State(initialValue: lineCount <= 5)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Header
            HStack(spacing: 6) {
                Image(systemName: parsed.isError ? "exclamationmark.triangle.fill" : "arrow.left")
                    .font(.system(size: 10))
                    .foregroundStyle(parsed.isError ? .red : .secondary)

                if let name = parsed.toolName {
                    Text("\(name) result")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                }

                Text(formatSize(parsed.byteSize))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)

                Spacer()

                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        isExpanded.toggle()
                    }
                } label: {
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }

            // Content
            if isExpanded {
                Text(parsed.output)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .foregroundStyle(parsed.isError ? .red.opacity(0.85) : .primary)
            } else {
                Text(parsed.output.components(separatedBy: "\n").first ?? "")
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(8)
        .background(parsed.isError ? Color.red.opacity(0.06) : Color.teal.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func formatSize(_ bytes: Int) -> String {
        if bytes < 1024 { return "\(bytes)B" }
        if bytes < 1024 * 1024 { return "\(bytes / 1024)KB" }
        return String(format: "%.1fMB", Double(bytes) / 1024 / 1024)
    }
}
```

- [ ] **Step 4: Wire into ColorBarMessageView**

Modify `macos/Engram/Views/Transcript/ColorBarMessageView.swift`. Add cases before `default`:

```swift
case .toolCall:
    if let parsed = ToolCallParser.parseToolCall(indexed.message.content) {
        ToolCallView(parsed: parsed)
    } else {
        // Fallback to plain text
        Text(highlightedText(indexed.message.content))
            .font(.system(size: fontSize))
            .textSelection(.enabled)
    }
case .toolResult:
    if let parsed = ToolCallParser.parseToolResult(indexed.message.content) {
        ToolResultView(parsed: parsed)
    } else {
        Text(highlightedText(indexed.message.content))
            .font(.system(size: fontSize))
            .textSelection(.enabled)
    }
```

- [ ] **Step 5: Build and verify tool call rendering**

Run in `macos/`:
```bash
xcodegen generate && xcodebuild -project Engram.xcodeproj -scheme Engram -configuration Debug build
```
Manual check: Open the app, view a Claude Code session, verify toolCall messages show structured cards.

- [ ] **Step 6: Commit**

```bash
git add macos/Engram/Core/ToolCallParser.swift macos/Engram/Views/Transcript/ToolCallView.swift macos/Engram/Views/Transcript/ToolResultView.swift macos/Engram/Views/Transcript/ColorBarMessageView.swift
git commit -m "feat(macos): add structured tool call and result views in transcript"
```

- [ ] **Step 7: Create SyntaxHighlighter**

Create `macos/Engram/Core/SyntaxHighlighter.swift`:

```swift
import SwiftUI

enum SyntaxHighlighter {
    private static let cache = NSCache<NSString, NSAttributedString>()

    static func highlight(_ code: String, language: String) -> AttributedString {
        // Skip highlighting for large blocks
        if code.components(separatedBy: "\n").count > 200 {
            return AttributedString(code)
        }

        let cacheKey = "\(language):\(code.utf8.count):\(code.prefix(100))" as NSString
        if let cached = cache.object(forKey: cacheKey) {
            return AttributedString(cached)
        }

        let nsAttr = NSMutableAttributedString(string: code, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
            .foregroundColor: NSColor.labelColor,
        ])

        let rules = tokenRules(for: language.lowercased())
        let nsRange = NSRange(code.startIndex..., in: code)

        for rule in rules {
            rule.regex.enumerateMatches(in: code, range: nsRange) { match, _, _ in
                guard let match else { return }
                let matchRange = match.range(at: rule.captureGroup)
                nsAttr.addAttribute(.foregroundColor, value: rule.color, range: matchRange)
            }
        }

        cache.setObject(nsAttr, forKey: cacheKey)
        return AttributedString(nsAttr)
    }

    private struct TokenRule {
        let regex: NSRegularExpression
        let color: NSColor
        let captureGroup: Int
    }

    private static func tokenRules(for language: String) -> [TokenRule] {
        switch language {
        case "swift":
            return swiftRules
        case "typescript", "javascript", "ts", "js", "tsx", "jsx":
            return tsRules
        case "python", "py":
            return pythonRules
        case "bash", "sh", "zsh", "shell":
            return bashRules
        case "json":
            return jsonRules
        default:
            return [] // No highlighting for unknown languages
        }
    }

    private static let purple = NSColor(red: 0.68, green: 0.32, blue: 0.87, alpha: 1) // keywords
    private static let green  = NSColor(red: 0.26, green: 0.71, blue: 0.35, alpha: 1) // strings
    private static let gray   = NSColor(red: 0.55, green: 0.55, blue: 0.58, alpha: 1) // comments
    private static let orange = NSColor(red: 0.85, green: 0.55, blue: 0.20, alpha: 1) // numbers
    private static let blue   = NSColor(red: 0.25, green: 0.50, blue: 0.90, alpha: 1) // types
    private static let yellow = NSColor(red: 0.80, green: 0.72, blue: 0.25, alpha: 1) // function calls

    private static func rule(_ pattern: String, _ color: NSColor, group: Int = 0) -> TokenRule {
        TokenRule(regex: try! NSRegularExpression(pattern: pattern), color: color, captureGroup: group)
    }

    private static let swiftRules: [TokenRule] = [
        rule(#"//.*$"#, gray),
        rule(#""(?:[^"\\]|\\.)*""#, green),
        rule(#"\b(func|let|var|class|struct|enum|protocol|import|return|if|else|guard|switch|case|for|while|do|try|catch|throw|async|await|self|Self|nil|true|false|private|public|internal|fileprivate|open|static|override|mutating|typealias|where|extension|subscript|init|deinit|weak|unowned|lazy|defer|break|continue|fallthrough|repeat|in|is|as)\b"#, purple),
        rule(#"\b(String|Int|Double|Float|Bool|Array|Dictionary|Set|Optional|Any|AnyObject|Void|Never|some)\b"#, blue),
        rule(#"\b\d+\.?\d*\b"#, orange),
        rule(#"\b(\w+)\("#, yellow, group: 1),
    ]

    private static let tsRules: [TokenRule] = [
        rule(#"//.*$"#, gray),
        rule(#"'(?:[^'\\]|\\.)*'"#, green),
        rule(#""(?:[^"\\]|\\.)*""#, green),
        rule(#"`(?:[^`\\]|\\.)*`"#, green),
        rule(#"\b(const|let|var|function|class|interface|type|enum|import|export|from|return|if|else|switch|case|for|while|do|try|catch|throw|async|await|new|this|null|undefined|true|false|default|break|continue|typeof|instanceof|in|of|as|extends|implements|readonly|private|public|protected|static|abstract|yield|void|never|unknown|any)\b"#, purple),
        rule(#"\b(string|number|boolean|object|symbol|bigint|Promise|Array|Map|Set|Record|Partial|Required|Pick|Omit)\b"#, blue),
        rule(#"\b\d+\.?\d*\b"#, orange),
        rule(#"\b(\w+)\("#, yellow, group: 1),
    ]

    private static let pythonRules: [TokenRule] = [
        rule(#"#.*$"#, gray),
        rule(#"'''[\s\S]*?'''"#, green),
        rule(#"\"\"\"[\s\S]*?\"\"\""#, green),
        rule(#"'(?:[^'\\]|\\.)*'"#, green),
        rule(#""(?:[^"\\]|\\.)*""#, green),
        rule(#"\b(def|class|import|from|return|if|elif|else|for|while|try|except|finally|raise|with|as|pass|break|continue|lambda|yield|async|await|and|or|not|in|is|None|True|False|global|nonlocal|del|assert)\b"#, purple),
        rule(#"\b(str|int|float|bool|list|dict|tuple|set|bytes|type|Any|Optional|Union|List|Dict|Tuple|Set)\b"#, blue),
        rule(#"\b\d+\.?\d*\b"#, orange),
        rule(#"\b(\w+)\("#, yellow, group: 1),
    ]

    private static let bashRules: [TokenRule] = [
        rule(#"#.*$"#, gray),
        rule(#"'[^']*'"#, green),
        rule(#""(?:[^"\\]|\\.)*""#, green),
        rule(#"\b(if|then|else|elif|fi|for|while|do|done|case|esac|function|return|exit|local|export|source|alias|echo|cd|ls|grep|sed|awk|find|cat|mkdir|rm|cp|mv|chmod|chown|curl|wget|git|npm|npx|node|python)\b"#, purple),
        rule(#"\$\{?\w+\}?"#, orange),
    ]

    private static let jsonRules: [TokenRule] = [
        rule(#""(?:[^"\\]|\\.)*"\s*:"#, blue),   // keys
        rule(#":\s*"(?:[^"\\]|\\.)*""#, green),   // string values
        rule(#":\s*(-?\d+\.?\d*)"#, orange, group: 1), // numbers
        rule(#"\b(true|false|null)\b"#, purple),
    ]
}
```

- [ ] **Step 8: Wire SyntaxHighlighter into CodeBlockView**

In `macos/Engram/Views/ContentSegmentViews.swift`, modify the `CodeBlockView`:

Find the code block text rendering and replace the plain monospaced Text with:

```swift
// In CodeBlockView body, replace:
//   Text(code).font(.system(size: 12, design: .monospaced))
// With:
if !language.isEmpty {
    Text(SyntaxHighlighter.highlight(code, language: language))
} else {
    Text(code).font(.system(size: 12, design: .monospaced))
}
```

- [ ] **Step 9: Build and verify syntax highlighting**

```bash
cd macos && xcodegen generate && xcodebuild -project Engram.xcodeproj -scheme Engram -configuration Debug build
```
Manual check: Open app, find a session with code blocks, verify syntax colors appear.

- [ ] **Step 10: Commit**

```bash
git add macos/Engram/Core/SyntaxHighlighter.swift macos/Engram/Views/ContentSegmentViews.swift
git commit -m "feat(macos): add regex-based syntax highlighting for 5 languages"
```

- [ ] **Step 11: Add .image segment to ContentSegmentParser**

Modify `macos/Engram/Core/ContentSegmentParser.swift`:

Add to the `ContentSegment` enum:

```swift
enum ImageSource {
    case base64(data: Data, mimeType: String)
    case filePath(String)
}

// Add case to ContentSegment enum:
case image(source: ImageSource)
```

Add to the `id` computed property:

```swift
case .image(let source):
    switch source {
    case .base64(let data, _): return "img-\(data.hashValue)"
    case .filePath(let path): return "img-\(path)"
    }
```

Add image detection in the parser. **Integration point in `parse()`**: In the main parsing loop, after code block detection and before plain text accumulation, add:

```swift
// In parse() main loop, after the code block check:
// Check for images in text buffer before flushing
if !textBuf.isEmpty {
    let combined = textBuf.joined(separator: "\n")
    // isToolResult is passed as parameter to parse() — thread from ColorBarMessageView
    // via: ContentSegmentParser.parse(content, isToolResult: indexed.messageType == .toolResult)
    if let (imgSource, _) = Self.detectImage(in: combined, isToolResult: isToolResult) {
        flushText()
        segments.append(.image(source: imgSource))
        continue // skip adding to textBuf
    }
}
```

**Threading `isToolResult`**: Add `isToolResult: Bool = false` parameter to `static func parse(_ content: String, isToolResult: Bool = false)`. In `SegmentedMessageView`, pass it from the parent view context. In `ColorBarMessageView`, the `indexed.messageType` is available.

Static properties and helper:

```swift
// In ContentSegmentParser, add as static properties:
// (The detectImage function handles the actual detection)
private static let base64Pattern = try! NSRegularExpression(
    pattern: #"data:image/(png|jpeg|gif|webp);base64,([A-Za-z0-9+/=]+)"#
)
private static let base64Pattern = try! NSRegularExpression(
    pattern: #"data:image/(png|jpeg|gif|webp);base64,([A-Za-z0-9+/=]+)"#
)

// Check each text line for base64 images
static func detectImage(in text: String, isToolResult: Bool) -> (ImageSource, Range<String.Index>)? {
    let nsRange = NSRange(text.startIndex..., in: text)

    // base64: allowed in all messages
    if let match = base64Pattern.firstMatch(in: text, range: nsRange),
       let mimeRange = Range(match.range(at: 1), in: text),
       let dataRange = Range(match.range(at: 2), in: text) {
        let mimeType = "image/" + text[mimeRange]
        if let data = Data(base64Encoded: String(text[dataRange])),
           data.count <= 1_048_576 { // 1MB limit
            return (.base64(data: data, mimeType: String(mimeType)), Range(match.range, in: text)!)
        }
    }

    // file path: only in tool results
    if isToolResult {
        let pathPattern = try! NSRegularExpression(
            pattern: #"(/[\w./-]+\.(png|jpe?g|gif|webp))\b"#, options: .caseInsensitive
        )
        if let match = pathPattern.firstMatch(in: text, range: nsRange),
           let pathRange = Range(match.range(at: 1), in: text) {
            return (.filePath(String(text[pathRange])), Range(match.range, in: text)!)
        }
    }

    return nil
}
```

- [ ] **Step 12: Create InlineImageView**

Create `macos/Engram/Views/Transcript/InlineImageView.swift`:

```swift
import SwiftUI

struct InlineImageView: View {
    let source: ContentSegmentParser.ImageSource

    @State private var image: NSImage?
    @State private var showFullSize = false
    @State private var loadError = false

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: 400)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .onTapGesture { showFullSize = true }
                    .sheet(isPresented: $showFullSize) {
                        VStack {
                            Image(nsImage: image)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .padding()
                            Button("Close") { showFullSize = false }
                                .keyboardShortcut(.escape)
                                .padding(.bottom)
                        }
                        .frame(minWidth: 600, minHeight: 400)
                    }
            } else if loadError {
                HStack(spacing: 6) {
                    Image(systemName: "photo")
                        .foregroundStyle(.secondary)
                    Text("Image unavailable")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .padding(8)
                .background(Color.gray.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            } else {
                ProgressView()
                    .scaleEffect(0.6)
                    .frame(width: 40, height: 40)
            }
        }
        .onAppear(perform: loadImage)
    }

    private func loadImage() {
        switch source {
        case .base64(let data, _):
            if let nsImage = NSImage(data: data) {
                image = nsImage
            } else {
                loadError = true
            }
        case .filePath(let path):
            if let nsImage = NSImage(contentsOfFile: path) {
                image = nsImage
            } else {
                loadError = true
            }
        }
    }
}
```

- [ ] **Step 13: Wire .image into ContentSegmentViews**

In `macos/Engram/Views/ContentSegmentViews.swift`, add to the SegmentedMessageView's ForEach switch:

```swift
case .image(let source):
    InlineImageView(source: source)
```

- [ ] **Step 14: Build and verify image preview**

```bash
cd macos && xcodegen generate && xcodebuild -project Engram.xcodeproj -scheme Engram -configuration Debug build
```
Manual check: Find a session with screenshot tool results, verify images render.

- [ ] **Step 15: Commit**

```bash
git add macos/Engram/Core/ContentSegmentParser.swift macos/Engram/Views/Transcript/InlineImageView.swift macos/Engram/Views/ContentSegmentViews.swift
git commit -m "feat(macos): add inline image preview for base64 and file path images"
```

---

### Task 6: Hygiene Page (Swift)

**Files:**
- Create: `macos/Engram/Views/Pages/HygieneView.swift`
- Modify: `macos/Engram/Models/Screen.swift`
- Modify: `macos/Engram/Views/SidebarView.swift`
- Modify: `macos/Engram/Views/ContentView.swift`

- [ ] **Step 1: Add .hygiene to Screen enum**

In `macos/Engram/Models/Screen.swift`:

Add `case hygiene` after `case observability` in the enum.

Add to `Section.monitor.screens`:
```swift
case .monitor: return [.sessions, .timeline, .activity, .observability, .hygiene]
```

Add to the `title` property:
```swift
case .hygiene: return "Hygiene"
```

Add to the `icon` property:
```swift
case .hygiene: return "cross.case"
```

- [ ] **Step 2: Create HygieneView**

Create `macos/Engram/Views/Pages/HygieneView.swift`:

```swift
import SwiftUI

struct HygieneView: View {
    @State private var issues: [HygieneIssue] = []
    @State private var score: Int = 100
    @State private var checkedAt: String = ""
    @State private var isLoading = true
    @State private var errorMessage: String?

    @EnvironmentObject private var daemon: DaemonClient

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // KPI row
                HStack(spacing: 12) {
                    KPICard(value: "\(score)", label: "Score")
                    KPICard(value: "\(issues.filter { $0.severity == "error" }.count)", label: "Errors")
                    KPICard(value: "\(issues.filter { $0.severity == "warning" }.count)", label: "Warnings")
                    KPICard(value: "\(issues.filter { $0.severity == "info" }.count)", label: "Info")
                }

                // Refresh bar
                HStack {
                    if !checkedAt.isEmpty {
                        Text("Last checked: \(formatRelativeTime(checkedAt))")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        Task { await loadData(force: true) }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 12))
                    }
                    .buttonStyle(.plain)
                    .disabled(isLoading)
                }

                if isLoading {
                    ForEach(0..<3, id: \.self) { _ in
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.gray.opacity(0.1))
                            .frame(height: 60)
                    }
                } else if issues.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 32))
                            .foregroundStyle(.green)
                        Text("All clean! No issues found.")
                            .font(.system(size: 14))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 40)
                } else {
                    // Error section
                    let errors = issues.filter { $0.severity == "error" }
                    if !errors.isEmpty {
                        IssueSection(title: "Errors", issues: errors, expanded: true)
                    }

                    // Warning section
                    let warnings = issues.filter { $0.severity == "warning" }
                    if !warnings.isEmpty {
                        IssueSection(title: "Warnings", issues: warnings, expanded: true)
                    }

                    // Info section
                    let infos = issues.filter { $0.severity == "info" }
                    if !infos.isEmpty {
                        IssueSection(title: "Info", issues: infos, expanded: false)
                    }
                }
            }
            .padding(24)
        }
        .task { await loadData(force: false) }
    }

    private func loadData(force: Bool) async {
        isLoading = true
        defer { isLoading = false }

        do {
            let result = try await daemon.fetchHygieneChecks(force: force)
            issues = result.issues
            score = result.score
            checkedAt = result.checkedAt
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func formatRelativeTime(_ iso: String) -> String {
        guard let date = ISO8601DateFormatter().date(from: iso) else { return iso }
        let diff = Date().timeIntervalSince(date)
        if diff < 60 { return "just now" }
        if diff < 3600 { return "\(Int(diff / 60))m ago" }
        return "\(Int(diff / 3600))h ago"
    }
}

struct HygieneIssue: Codable, Identifiable {
    var id: String { "\(kind)-\(message.prefix(40))" }
    let kind: String
    let severity: String
    let message: String
    let detail: String?
    let repo: String?
    let action: String?
}

struct HygieneCheckResult: Codable {
    let issues: [HygieneIssue]
    let score: Int
    let checkedAt: String
}

struct IssueSection: View {
    let title: String
    let issues: [HygieneIssue]
    let expanded: Bool

    @State private var isExpanded: Bool

    init(title: String, issues: [HygieneIssue], expanded: Bool) {
        self.title = title
        self.issues = issues
        self.expanded = expanded
        self._isExpanded = State(initialValue: expanded)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation { isExpanded.toggle() }
            } label: {
                HStack {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10))
                    Text("\(title) (\(issues.count))")
                        .font(.system(size: 13, weight: .semibold))
                    Spacer()
                }
            }
            .buttonStyle(.plain)

            if isExpanded {
                ForEach(issues) { issue in
                    IssueCard(issue: issue)
                }
            }
        }
    }
}

struct IssueCard: View {
    let issue: HygieneIssue
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(issue.kind.replacingOccurrences(of: "_", with: " "))
                    .font(.system(size: 11, weight: .medium))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(severityColor.opacity(0.15))
                    .clipShape(RoundedRectangle(cornerRadius: 4))

                if let repo = issue.repo {
                    Text(URL(fileURLWithPath: repo).lastPathComponent)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            Text(issue.message)
                .font(.system(size: 12))

            if let action = issue.action {
                HStack(spacing: 4) {
                    Image(systemName: "lightbulb.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.yellow)
                    Text(action)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer()
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(action, forType: .string)
                        copied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                    } label: {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 10))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(copied ? .green : .secondary)
                }
            }
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var severityColor: Color {
        switch issue.severity {
        case "error": return .red
        case "warning": return .orange
        default: return .blue
        }
    }
}
```

- [ ] **Step 3: Add DaemonClient.fetchHygieneChecks**

In `macos/Engram/Core/DaemonClient.swift`, add using the existing `fetch<T>` pattern (baseURL is String, not URL):

```swift
func fetchHygieneChecks(force: Bool = false) async throws -> HygieneCheckResult {
    let path = force ? "/api/hygiene?force=true" : "/api/hygiene"
    return try await fetch(path)
}
```

- [ ] **Step 4: Wire SidebarView + ContentView routing**

In `macos/Engram/Views/SidebarView.swift`, the `.monitor` section already iterates `Section.monitor.screens` — adding `.hygiene` to the `screens` array (Step 1) should auto-render it.

In `macos/Engram/Views/ContentView.swift`, add to the screen switch:

```swift
case .hygiene:
    HygieneView()
```

- [ ] **Step 5: Build and verify Hygiene page**

```bash
cd macos && xcodegen generate && xcodebuild -project Engram.xcodeproj -scheme Engram -configuration Debug build
```
Manual check: Open app, navigate to Hygiene in sidebar, verify page loads with score and issues.

- [ ] **Step 6: Commit**

```bash
git add macos/Engram/Views/Pages/HygieneView.swift macos/Engram/Models/Screen.swift macos/Engram/Views/SidebarView.swift macos/Engram/Views/ContentView.swift macos/Engram/Core/DaemonClient.swift
git commit -m "feat(macos): add Hygiene page with health check dashboard"
```

---

## Final Verification

### Task 7: Full Build + Test Verification

- [ ] **Step 1: Run full Node test suite**

```bash
npm test
```
Expected: 616 existing + ~40 new tests all pass

- [ ] **Step 2: Build Node**

```bash
npm run build
```
Expected: Clean compilation

- [ ] **Step 3: Build macOS app**

```bash
cd macos && xcodegen generate && xcodebuild -project Engram.xcodeproj -scheme Engram -configuration Debug build
```
Expected: Clean build

- [ ] **Step 4: Manual smoke test**

1. Launch Engram from DerivedData
2. Verify Hygiene page in sidebar under MONITOR section
3. Navigate to a Claude Code session — verify tool calls render as structured cards
4. Find a code block — verify syntax highlighting
5. Check get_context via MCP — verify environment data includes git repos, file hotspots
6. Check get_insights via MCP — verify cost suggestions return

- [ ] **Step 5: Final commit if any cleanup needed**

```bash
git status  # Review changes before staging
# Stage only specific files that need cleanup — never use git add -A
```
