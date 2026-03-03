import { Hono } from 'hono'
import { serve } from '@hono/node-server'
import { join } from 'path'
import { Database } from './core/db.js'
import { ensureDataDirs } from './core/bootstrap.js'
import { readFileSettings } from './core/config.js'

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
