import { Hono } from 'hono'
import { serve } from '@hono/node-server'
import { join } from 'path'
import { Database } from './core/db.js'
import { ensureDataDirs, getAdapter } from './core/bootstrap.js'
import { readFileSettings } from './core/config.js'
import type { SourceName } from './adapters/types.js'
import { handleSearch } from './tools/search.js'
import { handleStats } from './tools/stats.js'
import { layout, sessionListPage, searchPage, statsPage, settingsPage, sessionDetailPage } from './web/views.js'
import type { VectorStore } from './core/vector-store.js'
import type { EmbeddingClient } from './core/embeddings.js'
import { SyncEngine, type SyncPeer } from './core/sync.js'

export function createApp(db: Database, opts?: {
  vectorStore?: VectorStore
  embeddingClient?: EmbeddingClient
  syncEngine?: SyncEngine
  syncPeers?: SyncPeer[]
}) {
  const app = new Hono()

  app.get('/api/sync/status', (c) => {
    const settings = readFileSettings()
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
    const limit = parseInt(c.req.query('limit') ?? '100')
    const sessions = db.listSessionsSince(since, limit)
    return c.json({ sessions })
  })

  // Sync: manual trigger
  app.post('/api/sync/trigger', async (c) => {
    if (!opts?.syncEngine || !opts?.syncPeers?.length) {
      return c.json({ error: 'Sync not configured' }, 501)
    }
    const peerName = c.req.query('peer')
    const peers = peerName
      ? opts.syncPeers.filter(p => p.name === peerName)
      : opts.syncPeers

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
    return c.json({ sessions })
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
    const query = c.req.query('q') ?? ''
    const topK = parseInt(c.req.query('limit') ?? '10')

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

  // HTML routes
  app.get('/', (c) => {
    const sessions = db.listSessions({ limit: 50 })
    return c.html(sessionListPage(sessions))
  })

  app.get('/search', (c) => {
    return c.html(searchPage())
  })

  app.get('/stats', async (c) => {
    const result = await handleStats(db, {})
    return c.html(statsPage(result.groups, result.totalSessions))
  })

  app.get('/settings', (c) => {
    const settings = readFileSettings()
    return c.html(settingsPage({
      nodeName: settings.syncNodeName ?? 'unnamed',
      peers: settings.syncPeers ?? [],
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
const isMain = process.argv[1]?.endsWith('web.js') || process.argv[1]?.endsWith('web.ts')
if (isMain) {
  const DB_DIR = ensureDataDirs()
  const db = new Database(join(DB_DIR, 'index.sqlite'))
  const settings = readFileSettings()
  const port = settings.httpPort ?? 3457
  const app = createApp(db)

  serve({ fetch: app.fetch, port }, (info) => {
    process.stderr.write(`[engram-web] Listening on http://0.0.0.0:${info.port}\n`)
  })
}
