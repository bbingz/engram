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
import { SqliteVecStore } from './core/vector-store.js'
import { createEmbeddingClient } from './core/embeddings.js'
import { EmbeddingIndexer } from './core/embedding-indexer.js'
import type { EmbeddingClient } from './core/embeddings.js'
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

// Vector store — may fail if sqlite-vec can't load
let vectorStore: SqliteVecStore | undefined
let embeddingClient: EmbeddingClient | undefined
let embeddingIndexer: EmbeddingIndexer | undefined
try {
  vectorStore = new SqliteVecStore(db.getRawDb())
  embeddingClient = createEmbeddingClient({
    ollamaUrl: 'http://localhost:11434',
    openaiApiKey: settings.openaiApiKey,
  })
  embeddingIndexer = new EmbeddingIndexer(db, vectorStore, embeddingClient)
} catch (err) {
  emit({ event: 'warning', message: `Vector store unavailable: ${err}` })
}

// Initial full scan
indexer.indexAll().then(async (indexed) => {
  const total = db.countSessions()
  emit({ event: 'ready', indexed, total })

  if (embeddingIndexer) {
    try {
      const embedded = await embeddingIndexer.indexAll()
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

// Start web server
const port = settings.httpPort ?? 3457
const app = createApp(db, { vectorStore, embeddingClient })
const webServer = serve({ fetch: app.fetch, port }, (info) => {
  emit({ event: 'web_ready', port: info.port })
})

// Sync engine
const syncEngine = new SyncEngine(db)
const syncPeers = settings.syncPeers ?? []
const syncIntervalMs = (settings.syncIntervalMinutes ?? 30) * 60 * 1000

// Initial sync on startup
if (settings.syncEnabled && syncPeers.length > 0) {
  syncEngine.syncAllPeers(syncPeers).then(results => {
    const totalPulled = results.reduce((sum, r) => sum + r.pulled, 0)
    if (totalPulled > 0) {
      emit({ event: 'sync_complete', results, totalPulled })
    }
  }).catch(() => {})
}

// Periodic sync timer
const syncTimer = settings.syncEnabled && syncPeers.length > 0
  ? setInterval(async () => {
      try {
        const results = await syncEngine.syncAllPeers(syncPeers)
        const totalPulled = results.reduce((sum, r) => sum + r.pulled, 0)
        if (totalPulled > 0) {
          emit({ event: 'sync_complete', results, totalPulled })
        }
      } catch { /* ignore */ }
    }, syncIntervalMs)
  : null

// Lifecycle: stdin/parent/signal layers, no idle timeout for daemon
setupProcessLifecycle({
  idleTimeoutMs: 0,
  onExit: () => {
    clearInterval(rescanTimer)
    if (syncTimer) clearInterval(syncTimer)
    watcher?.close()
    webServer.close()
  },
})
