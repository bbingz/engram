import { Hono } from 'hono'
import { join } from 'path'
import { Database } from './core/db.js'
import { ensureDataDirs, getAdapter } from './core/bootstrap.js'
import { readFileSettings } from './core/config.js'
import type { FileSettings } from './core/config.js'
import type { SourceName } from './adapters/types.js'
import { handleSearch } from './tools/search.js'
import { handleStats } from './tools/stats.js'
import { layout, sessionListPage, searchPage, statsPage, settingsPage, sessionDetailPage } from './web/views.js'
import type { VectorStore } from './core/vector-store.js'
import type { EmbeddingClient } from './core/embeddings.js'
import { SyncEngine, type SyncPeer } from './core/sync.js'

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

export function createApp(db: Database, opts?: {
  vectorStore?: VectorStore
  embeddingClient?: EmbeddingClient
  syncEngine?: SyncEngine
  syncPeers?: SyncPeer[]
  settings?: FileSettings
}) {
  const app = new Hono()
  const settings = opts?.settings ?? readFileSettings()
  const semanticLimiter = createRateLimiter(30)

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

  // Full-text search
  app.get('/api/search', async (c) => {
    const q = c.req.query('q') ?? ''
    const source = c.req.query('source') as SourceName | undefined
    const project = c.req.query('project')
    const since = c.req.query('since')
    const limitParam = c.req.query('limit')
    const limit = limitParam ? parseInt(limitParam, 10) : undefined

    const result = await handleSearch(db, { query: q, source, project, since, limit })
    return c.json(result)
  })

  // Semantic search (vector)
  app.get('/api/search/semantic', async (c) => {
    if (!semanticLimiter()) {
      return c.json({ error: 'Rate limit exceeded — max 30 requests/minute' }, 429)
    }

    const query = c.req.query('q') ?? ''
    const topK = Math.min(parseInt(c.req.query('limit') ?? '10', 10), 50)

    if (!opts?.vectorStore || !opts?.embeddingClient) {
      return c.json({ error: 'Semantic search not available — no embedding provider configured' }, 501)
    }

    if (query.length < 2) {
      return c.json({ results: [], warning: 'Query too short' })
    }

    const embedding = await opts.embeddingClient.embed(query)
    if (!embedding) {
      return c.json({ error: 'Failed to generate embedding' }, 500)
    }

    const vecResults = opts.vectorStore.search(embedding, topK)
    const results = vecResults.map(vr => {
      const session = db.getSession(vr.sessionId)
      return { session, distance: vr.distance }
    }).filter(r => r.session !== null)

    return c.json({ results, query })
  })

  // Stats
  app.get('/api/stats', async (c) => {
    const since = c.req.query('since')
    const until = c.req.query('until')
    const group_by = c.req.query('group_by')

    const result = await handleStats(db, { since, until, group_by })
    return c.json(result)
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
    const result = await handleStats(db, { group_by: groupBy })
    return c.html(statsPage(result.groups, result.totalSessions, groupBy))
  })

  app.get('/settings', (c) => {
    return c.html(settingsPage({
      nodeName: settings.syncNodeName ?? 'unnamed',
      peers: settings.syncPeers ?? [],
      totalSessions: db.countSessions(),
      sources: db.listSources(),
      port: settings.httpPort ?? 3457,
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
  const app = createApp(db)

  serve({ fetch: app.fetch, port, hostname: '127.0.0.1' }, (info) => {
    process.stderr.write(`[engram-web] Listening on http://127.0.0.1:${info.port}\n`)
  })
}
