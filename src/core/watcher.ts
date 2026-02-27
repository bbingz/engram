// src/core/watcher.ts
import chokidar from 'chokidar'
import { homedir } from 'os'
import { join } from 'path'
import type { SessionAdapter, SourceName } from '../adapters/types.js'
import type { Indexer } from './indexer.js'

export function startWatcher(adapters: SessionAdapter[], indexer: Indexer): void {
  const home = homedir()
  const adaptersByName = new Map(adapters.map(a => [a.name, a]))
  const watchEntries: Array<[string, SourceName]> = [
    [join(home, '.codex', 'sessions'), 'codex'],
    [join(home, '.claude', 'projects'), 'claude-code'],
    [join(home, '.gemini', 'tmp'), 'gemini-cli'],
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
  if (watchPaths.length === 0) return

  const watcher = chokidar.watch(watchPaths, {
    persistent: true,
    ignoreInitial: true,
    awaitWriteFinish: { stabilityThreshold: 2000, pollInterval: 500 },
  })

  const handleChange = async (filePath: string) => {
    for (const [watchPath, adapter] of Object.entries(watchMap)) {
      if (filePath.startsWith(watchPath)) {
        await indexer.indexFile(adapter, filePath)
        break
      }
    }
  }

  watcher.on('add', handleChange)
  watcher.on('change', handleChange)
}
