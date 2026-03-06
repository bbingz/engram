// src/daemon.ts
// Stripped-down daemon: indexer + watcher only, no MCP server.
// Outputs JSON lines to stdout for the Swift app to parse.
// Usage: node dist/daemon.js [db-path]
import { join } from 'path'
import { Database } from './core/db.js'
import { Indexer } from './core/indexer.js'
import { startWatcher } from './core/watcher.js'
import { ensureDataDirs, createAdapters, initVectorDeps } from './core/bootstrap.js'
import { createApp } from './web.js'
import { readFileSettings } from './core/config.js'
import { SyncEngine } from './core/sync.js'

const DB_DIR = ensureDataDirs()
const dbPath = process.argv[2] || join(DB_DIR, 'index.sqlite')
const db = new Database(dbPath)
const adapters = createAdapters()
const indexer = new Indexer(db, adapters)
const settings = readFileSettings()

function emit(obj: object): void {
  process.stdout.write(JSON.stringify(obj) + '\n')
}

const vecDeps = initVectorDeps(db, {
  openaiApiKey: settings.openaiApiKey,
  ollamaUrl: settings.ollamaUrl,
  ollamaModel: settings.ollamaModel,
  embeddingDimension: settings.embeddingDimension,
})
if (!vecDeps) {
  emit({ event: 'warning', message: 'Vector store unavailable' })
}

// Initial full scan
indexer.indexAll().then(async (indexed) => {
  const total = db.countSessions()
  emit({ event: 'ready', indexed, total })

  // Backfill assistant/system counts for sessions indexed before this feature
  try {
    const backfilled = await indexer.backfillCounts()
    if (backfilled > 0) {
      emit({ event: 'backfill_counts', backfilled })
    }
  } catch { /* ignore */ }

  if (vecDeps) {
    try {
      const embedded = await vecDeps.embeddingIndexer.indexAll()
      if (embedded > 0) {
        emit({ event: 'embeddings_ready', embedded })
      }
    } catch { /* ignore */ }
  }
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

// Sync engine
const syncEngine = new SyncEngine(db)
const syncPeers = settings.syncPeers ?? []
const syncIntervalMs = Math.max(settings.syncIntervalMinutes ?? 30, 1) * 60 * 1000

async function syncAndEmit(): Promise<void> {
  const results = await syncEngine.syncAllPeers(syncPeers)
  const totalPulled = results.reduce((sum, r) => sum + r.pulled, 0)
  if (totalPulled > 0) {
    emit({ event: 'sync_complete', results, totalPulled })
  }
}

// Start web server
const port = settings.httpPort ?? 3457
const app = createApp(db, {
  vectorStore: vecDeps?.vectorStore,
  embeddingClient: vecDeps?.embeddingClient,
  syncEngine,
  syncPeers,
  settings,
})
const { serve } = await import('@hono/node-server')
const webServer = serve({ fetch: app.fetch, port, hostname: '127.0.0.1' }, (info) => {
  emit({ event: 'web_ready', port: info.port })
})

// Initial sync on startup
if (settings.syncEnabled && syncPeers.length > 0) {
  syncAndEmit().catch(() => {})
}

// Periodic sync timer
const syncTimer = settings.syncEnabled && syncPeers.length > 0
  ? setInterval(() => { syncAndEmit().catch(() => {}) }, syncIntervalMs)
  : null

// Lifecycle: signal handlers only (no stdin/parent checks — daemon runs standalone)
function shutdown() {
  clearInterval(rescanTimer)
  if (syncTimer) clearInterval(syncTimer)
  watcher?.close()
  webServer.close()
  db.close()
  process.exit(0)
}
process.on('SIGTERM', shutdown)
process.on('SIGINT', shutdown)
