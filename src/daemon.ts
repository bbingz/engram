// src/daemon.ts
// Stripped-down daemon: indexer + watcher only, no MCP server.
// Outputs JSON lines to stdout for the Swift app to parse.
// Usage: node dist/daemon.js [db-path]
import { join } from 'path'
import { Database } from './core/db.js'
import { Indexer } from './core/indexer.js'
import { startWatcher, WATCHED_SOURCES } from './core/watcher.js'
import { ensureDataDirs, createAdapters, initVectorDeps } from './core/bootstrap.js'
import { createApp } from './web.js'
import { readFileSettings, type FileSettings } from './core/config.js'
import { SyncEngine } from './core/sync.js'
import { AutoSummaryManager } from './core/auto-summary.js'
import { summarizeConversation } from './core/ai-client.js'
import { VikingBridge } from './core/viking-bridge.js'

const DB_DIR = ensureDataDirs()
const dbPath = process.argv[2] || join(DB_DIR, 'index.sqlite')
const db = new Database(dbPath)
const adapters = createAdapters()
const settings = readFileSettings()

// Viking bridge — optional external context engine
const vikingBridge = settings.viking?.enabled && settings.viking.url && settings.viking.apiKey
  ? new VikingBridge(settings.viking.url, settings.viking.apiKey)
  : null

const indexer = new Indexer(db, adapters, { viking: vikingBridge })

function emit(obj: object): void {
  process.stdout.write(JSON.stringify(obj) + '\n')
}

if (vikingBridge) {
  vikingBridge.isAvailable().then(available => {
    emit({ event: 'viking_status', available })
  }).catch(() => {
    emit({ event: 'viking_status', available: false })
  })
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

  // DB maintenance: dedup, optimize FTS, VACUUM if fragmented
  try {
    const deduped = db.deduplicateFilePaths()
    if (deduped > 0) emit({ event: 'db_maintenance', action: 'dedup', removed: deduped })
    db.optimizeFts()
    const vacuumed = db.vacuumIfNeeded(15) // VACUUM if >15% fragmentation
    if (vacuumed) emit({ event: 'db_maintenance', action: 'vacuum' })
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

// Auto-summary manager — lazily created when settings enable it
let autoSummary: AutoSummaryManager | undefined
let cachedAutoSummarySettings: FileSettings | undefined
let settingsCacheTime = 0
const SETTINGS_CACHE_TTL = 30_000 // re-read settings at most every 30s

function getCachedSettings(): FileSettings {
  const now = Date.now()
  if (!cachedAutoSummarySettings || now - settingsCacheTime > SETTINGS_CACHE_TTL) {
    cachedAutoSummarySettings = readFileSettings()
    settingsCacheTime = now
  }
  return cachedAutoSummarySettings
}

function getAutoSummary(): AutoSummaryManager | undefined {
  const current = getCachedSettings()
  if (!current.autoSummary || !current.aiApiKey) {
    if (autoSummary) { autoSummary.cleanup(); autoSummary = undefined }
    return undefined
  }
  if (!autoSummary) {
    autoSummary = new AutoSummaryManager({
      cooldownMs: (current.autoSummaryCooldown ?? 5) * 60 * 1000,
      minMessages: current.autoSummaryMinMessages ?? 4,
      hasSummary: (id) => {
        const s = db.getSession(id)
        if (!s?.summary) return false
        const fresh = getCachedSettings()
        if (!fresh.autoSummaryRefresh) return true
        const threshold = fresh.autoSummaryRefreshThreshold ?? 20
        const lastCount = s.summaryMessageCount
        return lastCount !== undefined && s.messageCount - lastCount < threshold
      },
      onTrigger: async (sessionId) => {
        const session = db.getSession(sessionId)
        if (!session) return
        const adapter = adapters.find(a => a.name === session.source)
        if (!adapter) return

        const messages: Array<{ role: string; content: string }> = []
        for await (const msg of adapter.streamMessages(session.filePath)) {
          messages.push({ role: msg.role, content: msg.content })
        }
        if (messages.length === 0) return

        try {
          // Fresh read for AI call (need latest API key/model)
          const currentSettings = readFileSettings()
          const summary = await summarizeConversation(messages, currentSettings)
          if (summary) {
            db.updateSessionSummary(sessionId, summary, messages.length)
            emit({ event: 'summary_generated', sessionId, summary, total: db.countSessions() })
          }
        } catch (err) {
          emit({ event: 'summary_error', sessionId, message: String(err) })
        }
      },
    })
  }
  return autoSummary
}

// File watcher (persistent — keeps process alive)
const watcher = startWatcher(adapters, indexer, {
  onIndexed: (sessionId, messageCount) => {
    emit({ event: 'watcher_indexed', total: db.countSessions() })
    getAutoSummary()?.onSessionIndexed(sessionId, messageCount)
  },
})

// Periodic re-scan every 10 minutes — only for non-watchable sources
// (SQLite-based: Cursor, OpenCode, VS Code, Windsurf, Copilot)
const RESCAN_INTERVAL = 10 * 60 * 1000
const allSourceNames = new Set(adapters.map(a => a.name))
const nonWatchable = new Set([...allSourceNames].filter(s => !WATCHED_SOURCES.has(s)))

const rescanTimer = setInterval(async () => {
  try {
    const indexed = nonWatchable.size > 0
      ? await indexer.indexAll({ sources: nonWatchable })
      : 0
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
    emit({ event: 'sync_complete', results, totalPulled, total: db.countSessions() })
  }
}

// Start web server
const port = settings.httpPort ?? 3457
const host = settings.httpHost ?? '127.0.0.1'
const app = createApp(db, {
  vectorStore: vecDeps?.vectorStore,
  embeddingClient: vecDeps?.embeddingClient,
  syncEngine,
  syncPeers,
  settings,
  adapters,
  viking: vikingBridge,
})
const { serve } = await import('@hono/node-server')
const webServer = serve({ fetch: app.fetch, port, hostname: host }, (info) => {
  emit({ event: 'web_ready', port: info.port, host })
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
  autoSummary?.cleanup()
  watcher?.close()
  webServer.close()
  db.close()
  process.exit(0)
}
process.on('SIGTERM', shutdown)
process.on('SIGINT', shutdown)
