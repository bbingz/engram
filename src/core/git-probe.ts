// src/core/git-probe.ts
import { execFileSync } from 'child_process'
import type Database from 'better-sqlite3'

export interface GitRepo {
  path: string
  name: string
  branch: string | null
  dirtyCount: number
  untrackedCount: number
  unpushedCount: number
  lastCommitHash: string | null
  lastCommitMsg: string | null
  lastCommitAt: string | null
  sessionCount: number
  probedAt: string
}

function gitCmd(repoPath: string, args: string): string | null {
  try {
    const argList = args.split(/\s+/)
    return execFileSync('git', ['-C', repoPath, ...argList], { encoding: 'utf-8', timeout: 10000 }).trim()
  } catch { return null }
}

export function discoverRepos(db: Database.Database): string[] {
  const rows = db.prepare(`
    SELECT DISTINCT cwd FROM sessions WHERE cwd IS NOT NULL AND cwd != '' AND (tier IS NULL OR tier != 'skip')
  `).all() as { cwd: string }[]

  const repos = new Set<string>()
  for (const { cwd } of rows) {
    const root = gitCmd(cwd, 'rev-parse --show-toplevel')
    if (root) repos.add(root)
  }
  return [...repos]
}

export function probeRepo(repoPath: string): Omit<GitRepo, 'sessionCount'> {
  const name = repoPath.split('/').pop() || repoPath
  const branch = gitCmd(repoPath, 'branch --show-current')
  const statusLines = (gitCmd(repoPath, 'status --porcelain') || '').split('\n').filter(Boolean)
  const dirtyCount = statusLines.filter(l => !l.startsWith('??')).length
  const untrackedCount = statusLines.filter(l => l.startsWith('??')).length
  const unpushedStr = gitCmd(repoPath, 'rev-list --count @{push}..HEAD')
  const unpushedCount = unpushedStr ? parseInt(unpushedStr, 10) || 0 : 0
  const logLine = gitCmd(repoPath, 'log --format=%H|%s|%aI -1')
  let lastCommitHash: string | null = null
  let lastCommitMsg: string | null = null
  let lastCommitAt: string | null = null
  if (logLine) {
    const parts = logLine.split('|')
    lastCommitHash = parts[0] || null
    lastCommitMsg = parts[1] || null
    lastCommitAt = parts.slice(2).join('|') || null
  }

  return {
    path: repoPath,
    name,
    branch,
    dirtyCount,
    untrackedCount,
    unpushedCount,
    lastCommitHash,
    lastCommitMsg,
    lastCommitAt,
    probedAt: new Date().toISOString()
  }
}

export function startGitProbeLoop(db: Database.Database, intervalMs = 300000) {
  const upsert = db.prepare(`
    INSERT INTO git_repos (path, name, branch, dirty_count, untracked_count, unpushed_count, last_commit_hash, last_commit_msg, last_commit_at, session_count, probed_at)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    ON CONFLICT(path) DO UPDATE SET
      name=excluded.name, branch=excluded.branch, dirty_count=excluded.dirty_count,
      untracked_count=excluded.untracked_count, unpushed_count=excluded.unpushed_count,
      last_commit_hash=excluded.last_commit_hash, last_commit_msg=excluded.last_commit_msg,
      last_commit_at=excluded.last_commit_at, session_count=excluded.session_count,
      probed_at=excluded.probed_at
  `)

  async function runOnce() {
    try {
      const repoPaths = discoverRepos(db)
      const sessionCounts = new Map<string, number>()
      const rows = db.prepare(`SELECT cwd, COUNT(*) as cnt FROM sessions WHERE cwd IS NOT NULL GROUP BY cwd`).all() as { cwd: string; cnt: number }[]
      for (const { cwd, cnt } of rows) {
        const root = gitCmd(cwd, 'rev-parse --show-toplevel')
        if (root) sessionCounts.set(root, (sessionCounts.get(root) || 0) + cnt)
      }

      for (const repoPath of repoPaths) {
        const info = probeRepo(repoPath)
        const count = sessionCounts.get(repoPath) || 0
        upsert.run(info.path, info.name, info.branch, info.dirtyCount, info.untrackedCount, info.unpushedCount, info.lastCommitHash, info.lastCommitMsg, info.lastCommitAt, count, info.probedAt)
      }
    } catch (err) {
      console.error('[git-probe] Error:', err) // stderr → os_log in daemon mode
    }
  }

  runOnce()
  return setInterval(runOnce, intervalMs)
}
