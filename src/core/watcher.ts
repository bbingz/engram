// src/core/watcher.ts
import chokidar, { type FSWatcher } from 'chokidar'
import { homedir } from 'os'
import { join } from 'path'
import type { SessionAdapter, SourceName } from '../adapters/types.js'
import type { Indexer } from './indexer.js'
import type { SessionTier } from './session-tier.js'

export interface WatcherOptions {
  onIndexed?: (sessionId: string, messageCount: number, tier: SessionTier) => void
}

/** Source names that have file watchers (jsonl-based, filesystem events work) */
export const WATCHED_SOURCES = new Set([
  'codex', 'claude-code', 'gemini-cli', 'antigravity', 'iflow', 'qwen', 'kimi', 'cline',
  // Derived sources that share claude-code's directory
  'lobsterai', 'minimax',
])

export function startWatcher(adapters: SessionAdapter[], indexer: Indexer, opts?: WatcherOptions): FSWatcher | null {
  const home = homedir()
  const adaptersByName = new Map(adapters.map(a => [a.name, a]))
  const watchEntries: Array<[string, SourceName]> = [
    [join(home, '.codex', 'sessions'), 'codex'],
    [join(home, '.claude', 'projects'), 'claude-code'],
    [join(home, '.gemini', 'tmp'), 'gemini-cli'],
    [join(home, '.gemini', 'antigravity'), 'antigravity'],
    [join(home, '.iflow', 'projects'), 'iflow'],
    [join(home, '.qwen', 'projects'), 'qwen'],
    [join(home, '.kimi', 'sessions'), 'kimi'],
    [join(home, '.cline', 'data', 'tasks'), 'cline'],
  ]
  const watchMap: Record<string, SessionAdapter> = {}
  for (const [path, name] of watchEntries) {
    const adapter = adaptersByName.get(name)
    if (adapter) watchMap[path] = adapter
  }

  const watchPaths = Object.keys(watchMap).filter(p => watchMap[p] !== undefined)
  if (watchPaths.length === 0) return null

  const watcher = chokidar.watch(watchPaths, {
    persistent: true,
    ignoreInitial: true,
    awaitWriteFinish: { stabilityThreshold: 2000, pollInterval: 500 },
  })

  const handleChange = async (filePath: string) => {
    for (const [watchPath, adapter] of Object.entries(watchMap)) {
      if (filePath.startsWith(watchPath)) {
        const result = await indexer.indexFile(adapter, filePath)
        if (result.indexed && result.sessionId) {
          opts?.onIndexed?.(result.sessionId, result.messageCount ?? 0, result.tier ?? 'normal')
        }
        break
      }
    }
  }

  watcher.on('add', handleChange)
  watcher.on('change', handleChange)

  return watcher
}
