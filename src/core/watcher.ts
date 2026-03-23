// src/core/watcher.ts
import chokidar, { type FSWatcher } from 'chokidar'
import { randomUUID } from 'crypto'
import { homedir } from 'os'
import { join } from 'path'
import type { SessionAdapter, SourceName } from '../adapters/types.js'
import type { Indexer } from './indexer.js'
import type { SessionTier } from './session-tier.js'
import { runWithContext } from './request-context.js'

export interface WatcherOptions {
  onIndexed?: (sessionId: string, messageCount: number, tier: SessionTier) => void
}

/** Source names that have file watchers (jsonl-based, filesystem events work) */
export const WATCHED_SOURCES = new Set([
  'codex', 'claude-code', 'gemini-cli', 'antigravity', 'iflow', 'qwen', 'kimi', 'cline',
  // Derived sources that share claude-code's directory
  'lobsterai', 'minimax',
])

/** Canonical mapping of watch directories to source names. Shared by watcher and daemon. */
export function getWatchEntries(home?: string): Array<[string, SourceName]> {
  const h = home ?? homedir()
  return [
    [join(h, '.codex', 'sessions'), 'codex'],
    [join(h, '.claude', 'projects'), 'claude-code'],
    [join(h, '.gemini', 'tmp'), 'gemini-cli'],
    [join(h, '.gemini', 'antigravity'), 'antigravity'],
    [join(h, '.iflow', 'projects'), 'iflow'],
    [join(h, '.qwen', 'projects'), 'qwen'],
    [join(h, '.kimi', 'sessions'), 'kimi'],
    [join(h, '.cline', 'data', 'tasks'), 'cline'],
  ]
}

export function startWatcher(adapters: SessionAdapter[], indexer: Indexer, opts?: WatcherOptions): FSWatcher | null {
  const home = homedir()
  const adaptersByName = new Map(adapters.map(a => [a.name, a]))
  const watchEntries = getWatchEntries(home)
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
    followSymlinks: false,
    awaitWriteFinish: { stabilityThreshold: 2000, pollInterval: 500 },
  })

  const handleChange = async (filePath: string) => {
    await runWithContext({ requestId: randomUUID(), source: 'watcher' }, async () => {
      for (const [watchPath, adapter] of Object.entries(watchMap)) {
        if (filePath.startsWith(watchPath)) {
          const result = await indexer.indexFile(adapter, filePath)
          if (result.indexed && result.sessionId) {
            opts?.onIndexed?.(result.sessionId, result.messageCount ?? 0, result.tier ?? 'normal')
          }
          break
        }
      }
    })
  }

  watcher.on('add', handleChange)
  watcher.on('change', handleChange)

  return watcher
}
