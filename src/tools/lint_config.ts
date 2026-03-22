import { readFileSync, existsSync, readdirSync } from 'fs'
import { execFileSync } from 'child_process'
import { join, extname, dirname, basename, resolve } from 'path'

export const lintConfigTool = {
  name: 'lint_config',
  description: 'Lint CLAUDE.md and similar config files: verify file references exist, npm scripts are valid, and detect stale instructions.',
  inputSchema: {
    type: 'object' as const,
    required: ['cwd'],
    properties: {
      cwd: { type: 'string', description: 'Project root directory' },
    },
    additionalProperties: false,
  },
}

export interface LintIssue {
  file: string
  line: number
  severity: 'error' | 'warning' | 'info'
  message: string
  suggestion?: string
}

/**
 * Extract backtick-wrapped references from a line of text.
 * Returns the content between each pair of backticks.
 */
export function extractBacktickRefs(line: string): string[] {
  const refs: string[] = []
  const regex = /`([^`]+)`/g
  let match
  while ((match = regex.exec(line)) !== null) {
    const content = match[1].trim()
    if (content.length > 0) refs.push(content)
  }
  return refs
}

/**
 * Check if a string looks like a file or directory path.
 */
export function looksLikeFilePath(ref: string): boolean {
  // Exclude URLs
  if (/^https?:\/\//.test(ref)) return false
  // Exclude scoped npm packages (e.g., @scope/pkg)
  if (ref.startsWith('@') && ref.includes('/') && !ref.includes(' ')) return false

  // Must contain a slash or have a recognized extension
  if (ref.includes(' ') && !ref.includes('/')) return false
  if (ref.endsWith('/')) return true

  const ext = extname(ref)
  if (ext && ext.length > 1 && ext.length <= 8) return true

  // Has a slash separator (like src/foo or macos/bar)
  if (ref.includes('/') && !ref.startsWith('-') && !ref.includes(' ')) return true

  return false
}

/**
 * Check if a string looks like an npm script reference.
 * Returns the script name if it does, null otherwise.
 */
export function looksLikeNpmScript(ref: string): string | null {
  // npm run <script>
  const runMatch = ref.match(/^npm\s+run\s+(\S+)/)
  if (runMatch) return runMatch[1]

  // npm <builtin> (test, start, stop, restart)
  const builtinMatch = ref.match(/^npm\s+(test|start|stop|restart)(?:\s|$)/)
  if (builtinMatch) return builtinMatch[1]

  return null
}

/**
 * Find config files in the project root and .claude directory.
 */
function findConfigFiles(cwd: string): string[] {
  const candidates = [
    join(cwd, 'CLAUDE.md'),
    join(cwd, '.claude', 'CLAUDE.md'),
    join(cwd, 'AGENTS.md'),
    join(cwd, '.cursorrules'),
    join(cwd, '.github', 'copilot-instructions.md'),
  ]
  return candidates.filter(f => existsSync(f))
}

/**
 * Try to find a similar file in the project directory.
 * Returns the closest match or undefined.
 */
function findSimilarFile(cwd: string, ref: string): string | undefined {
  const dir = dirname(join(cwd, ref))
  const name = basename(ref)

  try {
    if (!existsSync(dir)) return undefined
    const entries = readdirSync(dir)
    const nameLower = name.toLowerCase()

    // Exact case-insensitive match
    const caseMatch = entries.find(e => e.toLowerCase() === nameLower)
    if (caseMatch) {
      const relative = join(dirname(ref), caseMatch)
      return relative
    }

    // Extension swap (e.g., .ts -> .tsx, .js -> .ts)
    const base = name.replace(extname(name), '')
    const ext = extname(name)
    const swaps: Record<string, string[]> = {
      '.ts': ['.tsx', '.js', '.mjs'],
      '.tsx': ['.ts', '.jsx'],
      '.js': ['.ts', '.mjs', '.cjs'],
      '.jsx': ['.tsx', '.js'],
      '.swift': ['.m', '.mm'],
    }
    const alternatives = swaps[ext] ?? []
    for (const alt of alternatives) {
      const altName = base + alt
      if (entries.includes(altName)) {
        return join(dirname(ref), altName)
      }
    }
  } catch { /* directory may not be readable */ }

  return undefined
}

/**
 * Read package.json scripts from the project root.
 */
function readPackageJsonScripts(cwd: string): Record<string, string> | null {
  try {
    const pkgPath = join(cwd, 'package.json')
    if (!existsSync(pkgPath)) return null
    const pkg = JSON.parse(readFileSync(pkgPath, 'utf-8'))
    return pkg.scripts ?? {}
  } catch {
    return null
  }
}

export async function handleLintConfig(params: { cwd: string }): Promise<{ issues: LintIssue[]; score: number }> {
  const { cwd } = params
  const issues: LintIssue[] = []
  const configFiles = findConfigFiles(cwd)
  const scripts = readPackageJsonScripts(cwd)

  for (const configFile of configFiles) {
    let content: string
    try {
      content = readFileSync(configFile, 'utf-8')
    } catch {
      continue
    }

    const lines = content.split('\n')
    // Track if we're inside a fenced code block
    let inCodeBlock = false

    for (const [lineNum, line] of lines.entries()) {
      // Toggle code block state on fence markers
      if (line.trimStart().startsWith('```')) {
        inCodeBlock = !inCodeBlock
        continue
      }
      // Skip lines inside code blocks — references there are examples, not instructions
      if (inCodeBlock) continue

      const refs = extractBacktickRefs(line)

      for (const ref of refs) {
        // Check file references
        if (looksLikeFilePath(ref)) {
          const resolvedCwd = resolve(cwd)
          const fullPath = resolve(resolvedCwd, ref)
          // Skip refs that would escape the project root (path traversal)
          if (!fullPath.startsWith(resolvedCwd + '/') && fullPath !== resolvedCwd) continue
          if (!existsSync(fullPath)) {
            const suggestion = findSimilarFile(cwd, ref)
            issues.push({
              file: configFile,
              line: lineNum + 1,
              severity: 'error',
              message: `Referenced file \`${ref}\` does not exist`,
              suggestion: suggestion ? `Did you mean \`${suggestion}\`?` : undefined,
            })
          }
        }

        // Check npm script references
        const scriptName = looksLikeNpmScript(ref)
        if (scriptName && scripts !== null) {
          if (!scripts[scriptName]) {
            issues.push({
              file: configFile,
              line: lineNum + 1,
              severity: 'warning',
              message: `npm script \`${scriptName}\` not found in package.json`,
            })
          }
        }
      }
    }
  }

  // Score: 100 - (errors * 10) - (warnings * 3) - (info * 1), min 0
  const score = Math.max(0, 100 - issues.reduce((s, i) =>
    s + (i.severity === 'error' ? 10 : i.severity === 'warning' ? 3 : 1), 0))

  return { issues, score }
}

// ── Infrastructure Health Checks ────────────────────────────────────

export interface HealthIssue {
  kind: string
  severity: 'warning' | 'error' | 'info'
  message: string
  detail?: string
}

/** Check for stale git branches (merged into main but not deleted). */
export function checkStaleBranches(cwd: string): HealthIssue[] {
  try {
    const mainBranch = (() => {
      try {
        return execFileSync('git', ['symbolic-ref', 'refs/remotes/origin/HEAD', '--short'], { cwd, encoding: 'utf-8', timeout: 5000 }).trim().replace('origin/', '')
      } catch {
        return 'main'
      }
    })()
    const merged = execFileSync('git', ['branch', '--merged', mainBranch], { cwd, encoding: 'utf-8', timeout: 5000 })
    const stale = merged.split('\n')
      .map(b => b.trim().replace('* ', ''))
      .filter(b => b && b !== mainBranch && b !== 'master' && b !== 'main' && !b.startsWith('('))
    if (stale.length > 3) {
      return [{ kind: 'stale_branches', severity: 'info', message: `${stale.length} merged branches can be cleaned up`, detail: stale.slice(0, 5).join(', ') }]
    }
  } catch { /* not a git repo or git unavailable */ }
  return []
}

/** Check for large uncommitted changes. */
export function checkLargeUncommitted(cwd: string): HealthIssue[] {
  try {
    const status = execFileSync('git', ['status', '--porcelain'], { cwd, encoding: 'utf-8', timeout: 5000 })
    const files = status.split('\n').filter(l => l.trim())
    if (files.length > 20) {
      return [{ kind: 'large_uncommitted', severity: 'warning', message: `${files.length} uncommitted changes in ${basename(cwd)}`, detail: files.slice(0, 5).map(f => f.slice(3)).join(', ') }]
    }
  } catch { /* not a git repo */ }
  return []
}

/** Check for zombie node processes related to Engram. */
export function checkZombieProcesses(): HealthIssue[] {
  try {
    const ps = execFileSync('pgrep', ['-lf', 'engram.*daemon|daemon.*engram'], { encoding: 'utf-8', timeout: 3000 })
    const procs = ps.split('\n').filter(l => l.trim())
    if (procs.length > 2) {
      return [{ kind: 'zombie_processes', severity: 'warning', message: `${procs.length} Engram daemon processes running (expected 1)` }]
    }
  } catch { /* pgrep found nothing — normal */ }
  return []
}

/** Run all health checks for a project directory. */
export function runHealthChecks(cwd: string): HealthIssue[] {
  return [
    ...checkStaleBranches(cwd),
    ...checkLargeUncommitted(cwd),
    ...checkZombieProcesses(),
  ]
}
