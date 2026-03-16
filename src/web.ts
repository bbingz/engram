import { Hono } from 'hono'
import { join } from 'path'
import { Database } from './core/db.js'
import { ensureDataDirs, getAdapter } from './core/bootstrap.js'
import { readFileSettings } from './core/config.js'
import type { FileSettings } from './core/config.js'
import type { SessionAdapter, SourceName } from './adapters/types.js'
import { summarizeConversation } from './core/ai-client.js'
import { handleSearch, type SearchDeps } from './tools/search.js'
import { handleStats } from './tools/stats.js'
import { layout, sessionListPage, searchPage, statsPage, settingsPage, sessionDetailPage } from './web/views.js'
import type { VectorStore } from './core/vector-store.js'
import type { EmbeddingClient } from './core/embeddings.js'
import { SyncEngine, type SyncPeer } from './core/sync.js'
import { handleLinkSessions } from './tools/link_sessions.js'
import type { VikingBridge } from './core/viking-bridge.js'

function createRateLimiter(maxPerMinute: number) {
  const timestamps: number[] = []
  return (): boolean => {
    const now = Date.now()
    while (timestamps.length > 0 && timestamps[0] < now - 60_000) timestamps.shift()
    if (timestamps.length >= maxPerMinute) return false
    timestamps.push(now)
    return true
  }
}

// --- CIDR access control ---

export function ipToUint32(ip: string): number {
  const parts = ip.split('.').map(Number)
  return ((parts[0] << 24) | (parts[1] << 16) | (parts[2] << 8) | parts[3]) >>> 0
}

export function parseCIDR(cidr: string): { network: number; mask: number } {
  const [ip, prefixStr] = cidr.split('/')
  const prefix = Number(prefixStr ?? 32)
  const mask = prefix === 0 ? 0 : (~0 << (32 - prefix)) >>> 0
  return { network: (ipToUint32(ip) & mask) >>> 0, mask }
}

export function ipMatchesCIDR(ip: string, cidrs: Array<{ network: number; mask: number }>): boolean {
  // Always allow loopback
  if (ip === '127.0.0.1' || ip === '::1' || ip === '::ffff:127.0.0.1') return true
  // Normalize IPv4-mapped IPv6
  const v4 = ip.startsWith('::ffff:') ? ip.slice(7) : ip
  if (v4.includes(':')) return false // IPv6 not supported for CIDR matching
  const addr = ipToUint32(v4)
  return cidrs.some(c => ((addr & c.mask) >>> 0) === c.network)
}

export function createApp(db: Database, opts?: {
  vectorStore?: VectorStore
  embeddingClient?: EmbeddingClient
  syncEngine?: SyncEngine
  syncPeers?: SyncPeer[]
  settings?: FileSettings
  adapters?: SessionAdapter[]
  viking?: VikingBridge | null
}) {
  const app = new Hono()
  const settings = opts?.settings ?? readFileSettings()
  const semanticLimiter = createRateLimiter(30)

  // CIDR access control — only active when listening beyond localhost
  const host = settings.httpHost ?? '127.0.0.1'
  if (host !== '127.0.0.1' && settings.httpAllowCIDR?.length) {
    const allowedCIDRs = settings.httpAllowCIDR.map(parseCIDR)
    type ConnInfoFn = (c: unknown) => { remote: { address?: string } }
    let _getConnInfo: ConnInfoFn | null = null
    app.use('*', async (c, next) => {
      if (!_getConnInfo) {
        const mod = await import('@hono/node-server/conninfo')
        _getConnInfo = mod.getConnInfo as unknown as ConnInfoFn
      }
      const clientIP = _getConnInfo(c)?.remote?.address ?? '127.0.0.1'
      if (!ipMatchesCIDR(clientIP, allowedCIDRs)) {
        return c.text('Forbidden', 403)
      }
      await next()
    })
  }

  // Viking health: cache result with 60s TTL to avoid blocking /api/status
  let vikingAvailableCache = false
  let vikingCacheTime = 0
  const VIKING_CACHE_TTL = 60_000

  async function isVikingAvailable(): Promise<boolean> {
    if (!opts?.viking) return false
    const now = Date.now()
    if (now - vikingCacheTime < VIKING_CACHE_TTL) return vikingAvailableCache
    vikingAvailableCache = await opts.viking.isAvailable()
    vikingCacheTime = now
    return vikingAvailableCache
  }

  app.get('/api/sync/status', (c) => {
    return c.json({
      nodeName: settings.syncNodeName ?? 'unnamed',
      sessionCount: db.countSessions(),
      timestamp: new Date().toISOString(),
    })
  })

  // Sync: sessions since timestamp
  app.get('/api/sync/sessions', (c) => {
    const since = c.req.query('since')
    if (!since) return c.json({ error: 'since parameter required' }, 400)
    const limit = parseInt(c.req.query('limit') ?? '100', 10)
    const sessions = db.listSessionsSince(since, limit)
    return c.json({ sessions })
  })

  // Sync: manual trigger (re-reads peers from config to pick up Swift UI changes)
  app.post('/api/sync/trigger', async (c) => {
    if (!opts?.syncEngine) {
      return c.json({ error: 'Sync not configured' }, 501)
    }
    const freshSettings = readFileSettings()
    const freshPeers = freshSettings.syncPeers ?? opts.syncPeers ?? []
    if (!freshPeers.length) {
      return c.json({ error: 'No peers configured' }, 400)
    }
    const peerName = c.req.query('peer')
    const peers = peerName
      ? freshPeers.filter(p => p.name === peerName)
      : freshPeers

    const results = await opts.syncEngine.syncAllPeers(peers)
    return c.json({ results })
  })

  // General status
  app.get('/api/status', async (c) => {
    const totalSessions = db.countSessions()
    const sources = db.listSources()
    const projects = db.listProjects()
    const embeddedCount = opts?.vectorStore?.count() ?? 0
    const embeddingAvailable = !!(opts?.vectorStore && opts?.embeddingClient)
    const vikingAvailable = await isVikingAvailable()
    return c.json({
      totalSessions,
      sourceCount: sources.length,
      projectCount: projects.length,
      sources,
      projects,
      embeddingAvailable,
      embeddedCount,
      vikingAvailable,
    })
  })

  // Session list
  app.get('/api/sessions', (c) => {
    const source = c.req.query('source') as SourceName | undefined
    const project = c.req.query('project')
    const since = c.req.query('since')
    const until = c.req.query('until')
    const limitParam = c.req.query('limit')
    const offsetParam = c.req.query('offset')

    const limit = Math.min(limitParam ? parseInt(limitParam, 10) : 20, 100)
    const offset = offsetParam ? parseInt(offsetParam, 10) : 0

    const sessions = db.listSessions({ source, project, since, until, limit, offset })
    return c.json({ sessions, offset, limit, hasMore: sessions.length === limit })
  })

  // Session detail
  app.get('/api/sessions/:id', (c) => {
    const session = db.getSession(c.req.param('id'))
    if (!session) {
      return c.json({ error: 'Session not found' }, 404)
    }
    return c.json(session)
  })

  // Embedding status endpoint
  app.get('/api/search/status', (c) => {
    const totalSessions = db.countSessions()
    const embeddedCount = opts?.vectorStore?.count() ?? 0
    const available = !!(opts?.vectorStore && opts?.embeddingClient)
    return c.json({
      available,
      model: available ? opts!.embeddingClient!.model : null,
      embeddedCount,
      totalSessions,
      progress: totalSessions > 0 ? Math.round((embeddedCount / totalSessions) * 100) : 0,
    })
  })

  // Hybrid search (FTS + semantic + Viking)
  const searchDeps: SearchDeps = {
    ...(opts?.vectorStore && opts?.embeddingClient
      ? { vectorStore: opts.vectorStore, embed: (text: string) => opts!.embeddingClient!.embed(text) }
      : {}),
    viking: opts?.viking ?? null,
  }

  app.get('/api/search', async (c) => {
    const q = c.req.query('q') ?? ''
    const source = c.req.query('source') as SourceName | undefined
    const project = c.req.query('project')
    const since = c.req.query('since')
    const limitParam = c.req.query('limit')
    const limit = limitParam ? parseInt(limitParam, 10) : undefined
    const mode = c.req.query('mode') as string | undefined
    const agents = c.req.query('agents') as 'hide' | undefined
    const tools = c.req.query('tools') as 'hide' | undefined

    try {
      const result = await handleSearch(db, { query: q, source, project, since, limit, mode, agents, tools }, searchDeps)
      return c.json(result)
    } catch (err) {
      return c.json({ results: [], query: q, searchModes: [], warning: 'Search failed: ' + String(err) })
    }
  })

  // Semantic search (backward compat — delegates to hybrid with mode=semantic)
  app.get('/api/search/semantic', async (c) => {
    if (!semanticLimiter()) {
      return c.json({ error: 'Rate limit exceeded — max 30 requests/minute' }, 429)
    }
    if (!opts?.vectorStore || !opts?.embeddingClient) {
      return c.json({ error: 'Semantic search not available — no embedding provider configured' }, 501)
    }
    const q = c.req.query('q') ?? ''
    const limitParam = c.req.query('limit')
    const limit = limitParam ? parseInt(limitParam, 10) : 10
    try {
      const result = await handleSearch(db, { query: q, limit, mode: 'semantic' }, searchDeps)
      return c.json(result)
    } catch (err) {
      return c.json({ results: [], query: q, searchModes: [], warning: 'Search failed: ' + String(err) })
    }
  })

  // Stats
  app.get('/api/stats', async (c) => {
    const since = c.req.query('since')
    const until = c.req.query('until')
    const group_by = c.req.query('group_by')
    const exclude_noise = c.req.query('exclude_noise') !== '0'  // default: true

    const result = await handleStats(db, { since, until, group_by, exclude_noise })
    return c.json(result)
  })

  // Project aliases
  app.get('/api/project-aliases', (c) => {
    return c.json(db.listProjectAliases())
  })

  app.post('/api/project-aliases', async (c) => {
    const body = await c.req.json() as { alias?: string; canonical?: string }
    if (!body.alias || !body.canonical) return c.json({ error: 'alias and canonical required' }, 400)
    db.addProjectAlias(body.alias, body.canonical)
    return c.json({ added: { alias: body.alias, canonical: body.canonical } })
  })

  app.delete('/api/project-aliases', async (c) => {
    const body = await c.req.json() as { alias?: string; canonical?: string }
    if (!body.alias || !body.canonical) return c.json({ error: 'alias and canonical required' }, 400)
    db.removeProjectAlias(body.alias, body.canonical)
    return c.json({ removed: { alias: body.alias, canonical: body.canonical } })
  })

  // --- Summary API ---
  app.post('/api/summary', async (c) => {
    const body = await c.req.json().catch(() => ({}))
    const sessionId = (body as Record<string, unknown>).sessionId as string | undefined
    if (!sessionId) {
      return c.json({ error: 'Missing required field: sessionId' }, 400)
    }

    const session = db.getSession(sessionId)
    if (!session) {
      return c.json({ error: `Session not found: ${sessionId}` }, 404)
    }

    const currentSettings = readFileSettings()
    if (!currentSettings.aiApiKey) {
      return c.json({ error: 'API key not configured. Please set it in Settings.' }, 500)
    }

    const adapter = opts?.adapters?.find(a => a.name === session.source)
    if (!adapter) {
      return c.json({ error: `No adapter for source: ${session.source}` }, 500)
    }

    const messages: Array<{ role: string; content: string }> = []
    try {
      for await (const msg of adapter.streamMessages(session.filePath)) {
        messages.push({ role: msg.role, content: msg.content })
      }
    } catch (err) {
      return c.json({ error: `Failed to read session: ${err}` }, 500)
    }

    if (messages.length === 0) {
      return c.json({ error: 'No messages in session' }, 400)
    }

    try {
      const summary = await summarizeConversation(messages, currentSettings)
      if (!summary) {
        return c.json({ error: 'Empty response from AI' }, 500)
      }
      db.updateSessionSummary(sessionId, summary, messages.length)
      return c.json({ summary })
    } catch (err) {
      const msg = err instanceof Error ? err.message : String(err)
      return c.json({ error: msg }, 500)
    }
  })

  // --- Link sessions API ---
  app.post('/api/link-sessions', async (c) => {
    const body = await c.req.json().catch(() => ({}))
    const targetDir = (body as Record<string, unknown>).targetDir as string | undefined
    if (!targetDir) {
      return c.json({ error: 'Missing required field: targetDir' }, 400)
    }
    try {
      const result = await handleLinkSessions(db, { targetDir })
      return c.json(result)
    } catch (err) {
      const msg = err instanceof Error ? err.message : String(err)
      return c.json({ error: msg }, 500)
    }
  })

  // UUID lookup redirect
  app.get('/goto', (c) => {
    const id = (c.req.query('id') ?? '').trim()
    if (id && db.getSession(id)) {
      return c.redirect(`/session/${encodeURIComponent(id)}`)
    }
    return c.redirect('/')
  })

  // HTML routes
  app.get('/', (c) => {
    const sourceParam = c.req.query('source') || ''
    const projectParam = c.req.query('project') || ''
    const selectedSources = sourceParam ? sourceParam.split(',').filter(Boolean) : []
    const selectedProjects = projectParam ? projectParam.split(',').filter(Boolean) : []
    const limitParam = c.req.query('limit')
    const offsetParam = c.req.query('offset')
    const agentsParam = c.req.query('agents') as 'hide' | 'only' | 'all' | undefined
    const agents = agentsParam === 'all' ? undefined : agentsParam === 'only' ? 'only' : 'hide'  // default: hide agents
    const limit = Math.min(limitParam ? parseInt(limitParam, 10) : 50, 100)
    const offset = offsetParam ? parseInt(offsetParam, 10) : 0

    const sessions = db.listSessions({ sources: selectedSources, projects: selectedProjects, limit, offset, agents })
    const total = db.countSessions({ sources: selectedSources, projects: selectedProjects, agents })
    const sources = db.listSources()
    const projects = db.listProjects()

    return c.html(sessionListPage(sessions, {
      offset, limit, hasMore: sessions.length === limit,
      total, selectedSources, sources, agents, selectedProjects, projects,
    }))
  })

  app.get('/search', (c) => {
    const recent = db.listSessions({ limit: 5 })
    return c.html(searchPage(recent))
  })

  app.get('/stats', async (c) => {
    const groupBy = c.req.query('group_by') ?? 'source'
    const excludeNoise = c.req.query('exclude_noise') !== '0'  // default: true
    const result = await handleStats(db, { group_by: groupBy, exclude_noise: excludeNoise })
    return c.html(statsPage(result.groups, result.totalSessions, groupBy, excludeNoise))
  })

  app.get('/settings', (c) => {
    return c.html(settingsPage({
      nodeName: settings.syncNodeName ?? 'unnamed',
      peers: settings.syncPeers ?? [],
      totalSessions: db.countSessions(),
      sources: db.listSources(),
      port: settings.httpPort ?? 3457,
      aliases: db.listProjectAliases(),
    }))
  })

  app.get('/session/:id', async (c) => {
    const session = db.getSession(c.req.param('id'))
    if (!session) return c.html(layout('Not Found', '<h2>Session not found</h2>'), 404)
    const adapter = getAdapter(session.source)
    const messages: { role: string; content: string }[] = []
    if (adapter) {
      try {
        for await (const msg of adapter.streamMessages(session.filePath)) {
          messages.push({ role: msg.role, content: msg.content })
        }
      } catch {
        // File may not exist (e.g. deleted or on another machine)
      }
    }
    return c.html(sessionDetailPage(session, messages))
  })

  return app
}

// CLI entry point
const isMain = import.meta.url === `file://${process.argv[1]}`
  || process.argv[1]?.endsWith('/web.js')
  || process.argv[1]?.endsWith('/web.ts')
if (isMain) {
  const { serve } = await import('@hono/node-server')
  const DB_DIR = ensureDataDirs()
  const db = new Database(join(DB_DIR, 'index.sqlite'))
  const settings = readFileSettings()
  const port = settings.httpPort ?? 3457
  const host = settings.httpHost ?? '127.0.0.1'
  const app = createApp(db, { settings })

  serve({ fetch: app.fetch, port, hostname: host }, (info) => {
    process.stderr.write(`[engram-web] Listening on http://${host}:${info.port}\n`)
  })
}
