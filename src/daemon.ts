// src/daemon.ts
// Stripped-down daemon: indexer + watcher only, no MCP server.
// Outputs JSON lines to stdout for the Swift app to parse.
// Usage: node dist/daemon.js [db-path]
import { join } from 'path'
// os/homedir no longer needed — getWatchEntries() handles it internally
import { Database } from './core/db.js'
import { Indexer } from './core/indexer.js'
import { IndexJobRunner } from './core/index-job-runner.js'
import { startWatcher, WATCHED_SOURCES, getWatchEntries } from './core/watcher.js'
import { ensureDataDirs, createAdapters, initVectorDeps, initViking } from './core/bootstrap.js'
import { createApp } from './web.js'
import { readFileSettings, type FileSettings } from './core/config.js'
import { SyncEngine } from './core/sync.js'
import { AutoSummaryManager } from './core/auto-summary.js'
import { summarizeConversation } from './core/ai-client.js'
import { startGitProbeLoop } from './core/git-probe.js'
import { UsageCollector } from './core/usage-collector.js'
import { TitleGenerator } from './core/title-generator.js'
import { LiveSessionMonitor, type WatchDir } from './core/live-sessions.js'
import { BackgroundMonitor } from './core/monitor.js'
import { populateMockData } from './core/mock-data.js'

const DB_DIR = ensureDataDirs()
const dbPath = process.argv[2] || join(DB_DIR, 'index.sqlite')
const db = new Database(dbPath)
const adapters = createAdapters()
const settings = readFileSettings()
const authoritativeNode = settings.syncNodeName ?? 'local'

// Apply tier-based noise filter
db.noiseFilter = settings.noiseFilter ?? 'hide-skip'

// Build watch directories for live session detection (reuse canonical entries from watcher)
const watchDirs: WatchDir[] = getWatchEntries().map(([path, source]) => ({ path, source }))

// Viking bridge — optional external context engine
const vikingBridge = initViking(settings)

const usageCollector = new UsageCollector(db.getRawDb(), (event, data) => emit({ event, ...(typeof data === 'object' && data !== null ? data : { data }) }))

const titleConfig = {
  provider: settings.titleProvider ?? 'ollama',
  baseUrl: settings.titleBaseUrl ?? 'http://localhost:11434',
  model: settings.titleModel ?? 'qwen2.5:3b',
  apiKey: settings.titleApiKey,
  autoGenerate: settings.titleAutoGenerate ?? false,
}
const titleGenerator = new TitleGenerator(titleConfig)

const indexer = new Indexer(db, adapters, { viking: vikingBridge, authoritativeNode, titleGenerator })

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
const indexJobRunner = new IndexJobRunner(db, vecDeps?.vectorStore, vecDeps?.embeddingClient)

// Handle --mock flag for development
if (process.argv.includes('--mock')) {
  populateMockData(db).then(stats => {
    emit({ event: 'mock_data', ...stats })
  }).catch(err => {
    emit({ event: 'error', message: `Mock data failed: ${String(err)}` })
  })
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

  // Backfill costs and tool analytics (multi-round, max 5 to cap startup time)
  try {
    let totalBackfilled = 0
    for (let round = 0; round < 5; round++) {
      const count = await indexer.backfillCosts()
      if (count === 0) break
      totalBackfilled += count
    }
    if (totalBackfilled > 0) {
      emit({ event: 'backfill', type: 'costs', count: totalBackfilled })
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

  try {
    const jobSummary = await indexJobRunner.runRecoverableJobs()
    if (jobSummary.completed > 0 || jobSummary.notApplicable > 0) {
      emit({ event: 'index_jobs_recovered', ...jobSummary })
    }
  } catch { /* ignore */ }
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
  onIndexed: (sessionId, messageCount, tier) => {
    emit({ event: 'watcher_indexed', total: db.countSessions() })
    if (tier === 'premium') {
      getAutoSummary()?.onSessionIndexed(sessionId, messageCount)
    }
    indexJobRunner.runRecoverableJobs().catch(() => {})
  },
})

// Live session monitor — detects active coding sessions via file mtime
const liveMonitor = new LiveSessionMonitor({ watchDirs })
liveMonitor.start(5000)

// Background monitor — periodic health checks + alerts
const monitorConfig = settings.monitor ?? { enabled: true }
const backgroundMonitor = new BackgroundMonitor(db, monitorConfig, (alert) => {
  emit({ event: 'alert', alert })
}, liveMonitor)
if (monitorConfig.enabled) {
  backgroundMonitor.start(600_000) // every 10 minutes
}

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
      indexJobRunner.runRecoverableJobs().catch(() => {})
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
    indexJobRunner.runRecoverableJobs().catch(() => {})
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
  usageCollector,
  titleGenerator,
  liveMonitor,
  backgroundMonitor,
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

// Git repo probe loop — runs once immediately, then every 5 minutes
const gitProbeTimer = startGitProbeLoop(db.getRawDb())

// Lifecycle: signal handlers only (no stdin/parent checks — daemon runs standalone)
function shutdown() {
  clearInterval(rescanTimer)
  if (syncTimer) clearInterval(syncTimer)
  clearInterval(gitProbeTimer)
  liveMonitor.stop()
  backgroundMonitor.stop()
  autoSummary?.cleanup()
  watcher?.close()
  webServer.close()
  db.close()
  process.exit(0)
}
process.on('SIGTERM', shutdown)
process.on('SIGINT', shutdown)
