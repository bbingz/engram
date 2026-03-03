// src/daemon.ts
// Stripped-down daemon: indexer + watcher only, no MCP server.
// Outputs JSON lines to stdout for the Swift app to parse.
// Usage: node dist/daemon.js [db-path]
import { join } from 'path'
import { Database } from './core/db.js'
import { Indexer } from './core/indexer.js'
import { startWatcher } from './core/watcher.js'
import { setupProcessLifecycle } from './core/lifecycle.js'
import { ensureDataDirs, createAdapters } from './core/bootstrap.js'
import { createApp } from './web.js'
import { serve } from '@hono/node-server'
import { readFileSettings } from './core/config.js'

const DB_DIR = ensureDataDirs()
const dbPath = process.argv[2] || join(DB_DIR, 'index.sqlite')
const db = new Database(dbPath)
const adapters = createAdapters()
const indexer = new Indexer(db, adapters)

function emit(obj: object): void {
  process.stdout.write(JSON.stringify(obj) + '\n')
}

// Initial full scan
indexer.indexAll().then(indexed => {
  const total = db.countSessions()
  emit({ event: 'ready', indexed, total })
}).catch(err => {
  emit({ event: 'error', message: String(err) })
})

// File watcher (persistent — keeps process alive)
const watcher = startWatcher(adapters, indexer)

// Periodic re-scan every 10 minutes to catch files the watcher might miss
// (e.g. rsync'd files, SQLite-based sources like Cursor/OpenCode/VS Code)
const RESCAN_INTERVAL = 10 * 60 * 1000
const rescanTimer = setInterval(async () => {
  try {
    const indexed = await indexer.indexAll()
    if (indexed > 0) {
      const total = db.countSessions()
      emit({ event: 'rescan', indexed, total })
    }
  } catch (_) { /* ignore */ }
}, RESCAN_INTERVAL)

// Start web server
const settings = readFileSettings()
const port = settings.httpPort ?? 3457
const app = createApp(db)
const webServer = serve({ fetch: app.fetch, port }, (info) => {
  emit({ event: 'web_ready', port: info.port })
})

// Lifecycle: stdin/parent/signal layers, no idle timeout for daemon
setupProcessLifecycle({
  idleTimeoutMs: 0,
  onExit: () => {
    clearInterval(rescanTimer)
    watcher?.close()
    webServer.close()
  },
})
