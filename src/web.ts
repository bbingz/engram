import { Hono } from 'hono'
import { serve } from '@hono/node-server'
import { join } from 'path'
import { Database } from './core/db.js'
import { ensureDataDirs } from './core/bootstrap.js'
import { readFileSettings } from './core/config.js'
import type { SourceName } from './adapters/types.js'
import { handleSearch } from './tools/search.js'
import { handleStats } from './tools/stats.js'

export function createApp(db: Database) {
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

  // Stats
  app.get('/api/stats', async (c) => {
    const since = c.req.query('since')
    const until = c.req.query('until')
    const group_by = c.req.query('group_by')

    const result = await handleStats(db, { since, until, group_by })
    return c.json(result)
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
