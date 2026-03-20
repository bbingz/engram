import { Hono } from 'hono'
import { existsSync } from 'fs'
import { readdir, readFile, stat } from 'fs/promises'
import { join } from 'path'
import { homedir } from 'os'
import { Database } from './core/db.js'
import { ensureDataDirs, getAdapter } from './core/bootstrap.js'
import { readFileSettings } from './core/config.js'
import type { FileSettings } from './core/config.js'
import type { SessionAdapter, SourceName } from './adapters/types.js'
import { summarizeConversation } from './core/ai-client.js'
import { handleSearch, type SearchDeps } from './tools/search.js'
import { handleStats } from './tools/stats.js'
import { handleGetCosts } from './tools/get_costs.js'
import { handleToolAnalytics } from './tools/tool_analytics.js'
import { handleHandoff } from './tools/handoff.js'
import { layout, sessionListPage, searchPage, statsPage, settingsPage, sessionDetailPage, healthPage } from './web/views.js'
import type { VectorStore } from './core/vector-store.js'
import type { EmbeddingClient } from './core/embeddings.js'
import { SyncEngine, type SyncPeer } from './core/sync.js'
import { handleLinkSessions } from './tools/link_sessions.js'
import { buildResumeCommand } from './core/resume-coordinator.js'
import type { VikingBridge } from './core/viking-bridge.js'
import { WATCHED_SOURCES } from './core/watcher.js'
import type { UsageCollector } from './core/usage-collector.js'
import type { TitleGenerator } from './core/title-generator.js'
import type { LiveSessionMonitor } from './core/live-sessions.js'
import type { BackgroundMonitor } from './core/monitor.js'
import { populateMockData, clearMockData } from './core/mock-data.js'
import { handleLintConfig } from './tools/lint_config.js'

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
  usageCollector?: UsageCollector
  titleGenerator?: TitleGenerator
  liveMonitor?: LiveSessionMonitor
  backgroundMonitor?: BackgroundMonitor
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

  app.get('/api/sync/status', (c) => {
    return c.json({
      nodeName: settings.syncNodeName ?? 'unnamed',
      sessionCount: db.countSessions(),
      timestamp: new Date().toISOString(),
    })
  })

  // Sync: sessions since timestamp
  app.get('/api/sync/sessions', (c) => {
    const limit = parseInt(c.req.query('limit') ?? '100', 10)
    const cursorIndexedAt = c.req.query('cursor_indexed_at')
    const cursorId = c.req.query('cursor_id')

    let sessions
    if (cursorIndexedAt && cursorId) {
      sessions = db.listSessionsAfterCursor({ indexedAt: cursorIndexedAt, sessionId: cursorId }, limit)
    } else {
      const since = c.req.query('since')
      if (!since) return c.json({ error: 'since parameter required' }, 400)
      sessions = db.listSessionsSince(since, limit)
    }

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
    const vikingAvailable = opts?.viking ? await opts.viking.checkAvailable() : false
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

  // Session timeline for replay
  app.get('/api/sessions/:id/timeline', async (c) => {
    const session = db.getSession(c.req.param('id'))
    if (!session) return c.json({ error: 'Session not found' }, 404)

    const adapter = opts?.adapters?.find(a => a.name === session.source)
    if (!adapter) return c.json({ error: `No adapter for source: ${session.source}` }, 500)

    const limitParam = c.req.query('limit')
    const offsetParam = c.req.query('offset')
    const limit = limitParam ? parseInt(limitParam, 10) : undefined
    if (limit !== undefined && (isNaN(limit) || limit < 1)) return c.json({ error: 'limit must be a positive integer' }, 400)
    const clampedLimit = limit !== undefined ? Math.min(limit, 500) : undefined
    const offset = offsetParam ? parseInt(offsetParam, 10) : 0
    if (isNaN(offset) || offset < 0) return c.json({ error: 'offset must be a non-negative integer' }, 400)

    const entries: Array<{
      index: number
      timestamp: string | undefined
      role: string
      type: string
      preview: string
      toolName?: string
      durationToNextMs?: number
      tokens?: { input: number; output: number }
    }> = []

    // When limit is set, collect limit + 1 entries to determine hasMore accurately.
    // If we get limit + 1, pop the last and set hasMore = true.
    const collectTarget = clampedLimit !== undefined ? clampedLimit + 1 : undefined

    try {
      let idx = 0
      let collected = 0
      let prevTimestamp: string | undefined
      for await (const msg of adapter.streamMessages(session.filePath)) {
        if (idx < offset) {
          idx++
          prevTimestamp = msg.timestamp
          // NOTE: durationToNextMs for the first entry after offset > 0 will be
          // computed relative to the last skipped message's timestamp, which is
          // correct. However the skipped entry itself won't have durationToNextMs
          // set — acceptable limitation for v1 pagination.
          continue
        }
        if (collectTarget !== undefined && collected >= collectTarget) {
          break
        }
        const entry: typeof entries[0] = {
          index: idx,
          timestamp: msg.timestamp,
          role: msg.role,
          type: msg.role === 'tool' ? 'tool_result'
              : msg.toolCalls?.length ? 'tool_use'
              : 'message',
          preview: msg.content.slice(0, 100),
        }
        if (msg.toolCalls?.length) {
          entry.toolName = msg.toolCalls[0].name
        }
        if (msg.usage) {
          entry.tokens = {
            input: msg.usage.inputTokens,
            output: msg.usage.outputTokens,
          }
        }
        // Compute gap to previous entry
        if (prevTimestamp && msg.timestamp) {
          const gap = new Date(msg.timestamp).getTime() - new Date(prevTimestamp).getTime()
          if (entries.length > 0) entries[entries.length - 1].durationToNextMs = gap
        }
        prevTimestamp = msg.timestamp
        entries.push(entry)
        idx++
        collected++
      }
    } catch (err) {
      return c.json({ error: `Failed to read session: ${err}` }, 500)
    }

    // If we collected more than the requested limit, there are more entries
    const hasMore = clampedLimit !== undefined && entries.length > clampedLimit
    if (hasMore) entries.pop()

    return c.json({
      sessionId: session.id,
      source: session.source,
      totalEntries: session.messageCount || entries.length,
      entries,
      ...(offset > 0 ? { offset } : {}),
      ...(clampedLimit !== undefined ? { limit: clampedLimit, hasMore } : {}),
    })
  })

  // Session resume — detect CLI tool and build resume command
  app.post('/api/session/:id/resume', (c) => {
    const session = db.getSession(c.req.param('id'))
    if (!session) return c.json({ error: 'Session not found', hint: '' }, 404)
    const result = buildResumeCommand(session.source, session.id, session.cwd ?? '')
    return c.json(result)
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

  // Cost tracking API
  app.get('/api/costs', (c) => {
    const group_by = c.req.query('group_by')
    const since = c.req.query('since')
    const until = c.req.query('until')
    const result = handleGetCosts(db, { group_by, since, until })
    return c.json(result)
  })

  app.get('/api/costs/sessions', (c) => {
    const rawLimit = parseInt(c.req.query('limit') || '20')
    const limit = Math.min(Math.max(isNaN(rawLimit) ? 20 : rawLimit, 1), 100)
    const rows = db.getRawDb().prepare(`
      SELECT c.*, s.source, s.project, s.start_time, s.summary
      FROM session_costs c JOIN sessions s ON c.session_id = s.id
      ORDER BY c.cost_usd DESC LIMIT ?
    `).all(limit)
    return c.json({ sessions: rows })
  })

  // Tool analytics API
  app.get('/api/tool-analytics', (c) => {
    const project = c.req.query('project')
    const since = c.req.query('since')
    const group_by = c.req.query('group_by')
    const result = handleToolAnalytics(db, { project, since, group_by })
    return c.json(result)
  })

  // Usage snapshots
  app.get('/api/usage', (c) => {
    const latest = opts?.usageCollector?.getLatest() ?? []
    return c.json({ usage: latest })
  })

  app.get('/api/repos', (c) => {
    const rows = db.getRawDb().prepare('SELECT * FROM git_repos ORDER BY last_commit_at DESC').all()
    return c.json({ repos: rows })
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

  // --- Handoff brief generation ---
  app.post('/api/handoff', async (c) => {
    const body = await c.req.json().catch(() => ({}))
    const cwd = (body as Record<string, unknown>).cwd as string | undefined
    if (!cwd) {
      return c.json({ error: 'Missing required field: cwd' }, 400)
    }
    const sessionId = (body as Record<string, unknown>).sessionId as string | undefined
    const format = (body as Record<string, unknown>).format as string | undefined
    const validFormats = ['markdown', 'plain']
    if (format && !validFormats.includes(format)) {
      return c.json({ error: `Invalid format: ${format}. Must be one of: ${validFormats.join(', ')}` }, 400)
    }
    try {
      const result = await handleHandoff(db, {
        cwd,
        sessionId,
        format: format as 'markdown' | 'plain' | undefined,
      }, opts?.adapters)
      return c.json(result)
    } catch (err) {
      return c.json({ error: `Handoff failed: ${err}` }, 500)
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

  // --- Viking backfill: push existing sessions to OpenViking ---
  app.post('/api/viking/backfill', async (c) => {
    if (!opts?.viking || !opts?.adapters) {
      return c.json({ error: 'Viking not configured or no adapters' }, 501)
    }
    const viking = opts.viking
    const available = await viking.checkAvailable()
    if (!available) {
      return c.json({ error: 'Viking server unreachable' }, 503)
    }

    const limit = parseInt(c.req.query('limit') ?? '100', 10)
    const offset = parseInt(c.req.query('offset') ?? '0', 10)
    const source = c.req.query('source')
    const sessions = db.listSessions({ source: source as any, limit, offset, agents: 'hide' })

    let pushed = 0
    let errors = 0
    for (const session of sessions) {
      try {
        const adapter = opts.adapters.find(a => a.name === session.source)
        if (!adapter) continue

        const messages: { role: string; content: string }[] = []
        for await (const msg of adapter.streamMessages(session.filePath)) {
          if ((msg.role === 'user' || msg.role === 'assistant') && msg.content.trim()) {
            messages.push({ role: msg.role, content: msg.content })
          }
        }
        if (messages.length === 0) continue

        const content = messages.map(m => `[${m.role}] ${m.content}`).join('\n\n')
        await viking.addResource(`engram-${session.source}-${session.id}`, content, {
          source: session.source,
          project: session.project ?? '',
          startTime: session.startTime,
        })
        pushed++
      } catch {
        errors++
      }
    }

    return c.json({ pushed, errors, total: sessions.length, offset, limit })
  })

  // --- Title generation ---
  app.post('/api/session/:id/generate-title', async (c) => {
    if (!opts?.titleGenerator) return c.json({ error: 'Title generation not configured' }, 400)
    const id = c.req.param('id')
    const session = db.getSession(id)
    if (!session) return c.json({ error: 'Session not found' }, 404)

    const adapter = opts?.adapters?.find(a => a.name === session.source)
    if (!adapter) return c.json({ error: `No adapter for source: ${session.source}` }, 500)

    const messages: { role: string; content: string }[] = []
    try {
      for await (const msg of adapter.streamMessages(session.filePath)) {
        messages.push({ role: msg.role, content: msg.content })
        if (messages.length >= 6) break
      }
    } catch (err) {
      return c.json({ error: `Failed to read session: ${err}` }, 500)
    }

    const title = await opts.titleGenerator.generate(messages)
    if (!title) return c.json({ error: 'Title generation returned empty result' }, 500)

    db.getRawDb().prepare('UPDATE sessions SET generated_title = ? WHERE id = ?').run(title, id)
    return c.json({ title })
  })

  app.post('/api/titles/regenerate-all', async (c) => {
    if (!opts?.titleGenerator) return c.json({ error: 'Title generation not configured' }, 400)

    const titleGenerator = opts.titleGenerator
    const adapters = opts.adapters

    // Get sessions needing titles
    const sessions = db.getRawDb().prepare(`
      SELECT id, source, file_path, message_count, tier
      FROM sessions
      WHERE (generated_title IS NULL OR generated_title = '')
        AND message_count >= 2
        AND (tier IS NULL OR tier NOT IN ('skip', 'lite'))
      ORDER BY start_time DESC
      LIMIT 500
    `).all() as { id: string; source: string; file_path: string; message_count: number; tier: string | null }[]

    const count = sessions.length

    // Run in background (don't await)
    ;(async () => {
      let generated = 0
      const isOllama = (titleGenerator as any).config?.provider === 'ollama'

      for (const session of sessions) {
        try {
          if (!session.file_path) continue

          const adapter = adapters?.find(a => a.name === session.source)
          if (!adapter) continue

          const messages: { role: string; content: string }[] = []
          try {
            for await (const msg of adapter.streamMessages(session.file_path)) {
              if ((msg.role === 'user' || msg.role === 'assistant') && msg.content.trim()) {
                messages.push({ role: msg.role, content: msg.content })
              }
              if (messages.length >= 6) break
            }
          } catch {
            continue
          }

          if (messages.length < 2) continue

          const title = await titleGenerator.generate(messages)
          if (title) {
            db.getRawDb().prepare('UPDATE sessions SET generated_title = ? WHERE id = ?').run(title, session.id)
            generated++
          }

          // Rate limit: 1 req/sec for non-Ollama providers
          if (!isOllama) {
            await new Promise(r => setTimeout(r, 1000))
          }
        } catch (err) {
          console.error(`[title-regen] Error for ${session.id}:`, err)
        }
      }
      console.log(`[title-regen] Completed: ${generated}/${count} titles generated`)
    })()

    return c.json({ status: 'started', total: count, message: `Regenerating titles for ${count} sessions in background` })
  })

  // --- Health dashboard ---
  const HOME = homedir()
  const SOURCE_PATHS: Record<string, string> = {
    'claude-code': join(HOME, '.claude/projects'),
    'codex': join(HOME, '.codex/sessions'),
    'gemini-cli': join(HOME, '.gemini/tmp'),
    'opencode': join(HOME, '.local/share/opencode/opencode.db'),
    'iflow': join(HOME, '.iflow/projects'),
    'qwen': join(HOME, '.qwen/projects'),
    'kimi': join(HOME, '.kimi/sessions'),
    'cline': join(HOME, '.cline/data/tasks'),
    'cursor': join(HOME, 'Library/Application Support/Cursor/User/globalStorage/state.vscdb'),
    'vscode': join(HOME, 'Library/Application Support/Code/User/workspaceStorage'),
    'antigravity': join(HOME, '.gemini/antigravity/daemon'),
    'windsurf': join(HOME, '.codeium/windsurf/daemon'),
    'copilot': join(HOME, '.copilot/session-state'),
  }
  const DERIVED_SOURCES: Record<string, string> = {
    'lobsterai': 'claude-code',
    'minimax': 'claude-code',
  }

  async function getHealthData() {
    const sourceStats = db.getSourceStats()

    const sources = sourceStats.map(s => {
      const derivedFrom = DERIVED_SOURCES[s.source]
      const path = SOURCE_PATHS[derivedFrom ?? s.source] ?? ''
      return {
        name: s.source,
        sessionCount: s.sessionCount,
        latestIndexed: s.latestIndexed,
        path: path.replace(HOME, '~'),
        pathExists: path ? existsSync(path) : false,
        watcherType: WATCHED_SOURCES.has(s.source) ? 'watching' : 'polling',
        derived: !!derivedFrom,
        derivedFrom: derivedFrom ?? null,
        dailyCounts: s.dailyCounts,
      }
    })

    // Viking status (if configured)
    let viking: Record<string, unknown> | null = null
    if (opts?.viking) {
      try {
        const available = await opts.viking.checkAvailable()
        if (available) {
          const vikingUrl = opts.viking.url
          const vikingHeaders = opts.viking.apiHeaders
          const queueRes = await fetch(`${vikingUrl}/api/v1/observer/queue`, {
            headers: vikingHeaders,
            signal: AbortSignal.timeout(5000),
          }).then(r => r.json()).catch(() => null)
          const vlmRes = await fetch(`${vikingUrl}/api/v1/observer/vlm`, {
            headers: vikingHeaders,
            signal: AbortSignal.timeout(5000),
          }).then(r => r.json()).catch(() => null)
          viking = { available: true, queue: queueRes?.result?.status ?? null, vlm: vlmRes?.result?.status ?? null }
        } else {
          viking = { available: false }
        }
      } catch { viking = { available: false } }
    }

    const now = Date.now()
    const oneDayMs = 24 * 60 * 60 * 1000
    const activeSources = sourceStats.filter(s => {
      const latest = new Date(s.latestIndexed).getTime()
      return now - latest < oneDayMs
    }).length

    return {
      sources,
      viking,
      summary: {
        totalSources: sourceStats.length,
        activeSources,
        lastIndexed: sourceStats.length > 0
          ? sourceStats.reduce((a, b) => a.latestIndexed > b.latestIndexed ? a : b).latestIndexed
          : null,
      },
    }
  }

  app.get('/api/health/sources', async (c) => {
    return c.json(await getHealthData())
  })

  // Active sources with adapter info
  app.get('/api/sources', async (c) => {
    const sources = db.listSources()
    const stats = db.getSourceStats()
    const statsMap = new Map(stats.map(s => [s.source, s]))
    return c.json(sources.map(source => ({
      name: source,
      sessionCount: statsMap.get(source)?.sessionCount ?? 0,
      latestIndexed: statsMap.get(source)?.latestIndexed ?? null,
    })))
  })

  // Skills from Claude Code config
  app.get('/api/skills', async (c) => {
    const results: { name: string; description: string; path: string; scope: string }[] = []
    const home = homedir()

    // Global commands from settings
    try {
      const settingsPath = join(home, '.claude', 'settings.json')
      const raw = await readFile(settingsPath, 'utf-8')
      const settings = JSON.parse(raw)
      if (settings.customCommands) {
        for (const [name, cmd] of Object.entries(settings.customCommands)) {
          results.push({ name, description: String(cmd).slice(0, 100), path: settingsPath, scope: 'global' })
        }
      }
    } catch { /* no settings */ }

    // Plugin skills
    const pluginsDir = join(home, '.claude', 'plugins', 'cache')
    try {
      const vendors = await readdir(pluginsDir)
      for (const vendor of vendors) {
        const vendorPath = join(pluginsDir, vendor)
        const vendorStat = await stat(vendorPath).catch(() => null)
        if (!vendorStat?.isDirectory()) continue
        const items = await readdir(vendorPath, { recursive: true })
        for (const item of items) {
          if (typeof item === 'string' && item.endsWith('.md') && !item.includes('node_modules')) {
            try {
              const content = await readFile(join(vendorPath, item), 'utf-8')
              const nameMatch = content.match(/^name:\s*(.+)$/m)
              const descMatch = content.match(/^description:\s*(.+)$/m)
              if (nameMatch) {
                results.push({
                  name: nameMatch[1].trim(),
                  description: descMatch?.[1]?.trim() ?? '',
                  path: join(vendorPath, item).replace(home, '~'),
                  scope: 'plugin',
                })
              }
            } catch { /* skip unreadable */ }
          }
        }
      }
    } catch { /* no plugins dir */ }

    return c.json(results)
  })

  // Memory files across Claude Code projects
  app.get('/api/memory', async (c) => {
    const results: { name: string; project: string; path: string; sizeBytes: number; preview: string }[] = []
    const home = homedir()
    const projectsDir = join(home, '.claude', 'projects')

    try {
      const projects = await readdir(projectsDir)
      for (const project of projects) {
        const memoryDir = join(projectsDir, project, 'memory')
        try {
          const files = await readdir(memoryDir)
          for (const file of files) {
            if (!file.endsWith('.md')) continue
            const filePath = join(memoryDir, file)
            const fileStat = await stat(filePath).catch(() => null)
            if (!fileStat?.isFile()) continue
            const content = await readFile(filePath, 'utf-8').catch(() => '')
            results.push({
              name: file,
              project: project.replace(/-/g, '/'),
              path: filePath.replace(home, '~'),
              sizeBytes: fileStat.size,
              preview: content.slice(0, 200),
            })
          }
        } catch { /* no memory dir for this project */ }
      }
    } catch { /* no projects dir */ }

    return c.json(results)
  })

  // Hooks from Claude Code settings
  app.get('/api/hooks', async (c) => {
    const results: { event: string; command: string; scope: string }[] = []
    const home = homedir()

    for (const scope of ['global', 'project'] as const) {
      const path = scope === 'global'
        ? join(home, '.claude', 'settings.json')
        : join(home, '.claude', 'settings.local.json')
      try {
        const raw = await readFile(path, 'utf-8')
        const settings = JSON.parse(raw)
        if (settings.hooks) {
          for (const [event, handlers] of Object.entries(settings.hooks)) {
            if (Array.isArray(handlers)) {
              for (const handler of handlers) {
                const cmd = typeof handler === 'string' ? handler
                  : (handler as { command?: string }).command ?? JSON.stringify(handler)
                results.push({ event, command: cmd, scope })
              }
            }
          }
        }
      } catch { /* no settings file */ }
    }

    return c.json(results)
  })

  app.get('/health', async (c) => {
    return c.html(healthPage(await getHealthData()))
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

  // --- Live Sessions API ---
  // TODO: SSE endpoint (deferred) — add GET /api/live/stream that pushes live session
  // updates and monitor alerts via Server-Sent Events instead of polling.
  app.get('/api/live', (c) => {
    const sessions = opts?.liveMonitor?.getSessions() ?? []
    return c.json({ sessions, count: sessions.length })
  })

  // --- Monitor Alerts API ---
  app.get('/api/monitor/alerts', (c) => {
    const alerts = opts?.backgroundMonitor?.getAlerts() ?? []
    const undismissed = alerts.filter(a => !a.dismissed)
    return c.json({ alerts: undismissed, total: alerts.length })
  })

  app.post('/api/monitor/alerts/:id/dismiss', (c) => {
    const id = c.req.param('id')
    opts?.backgroundMonitor?.dismissAlert(id)
    return c.json({ dismissed: id })
  })

  // --- Dev Mode API ---
  app.post('/api/dev/mock', async (c) => {
    if (!settings.devMode) return c.json({ error: 'Dev mode not enabled' }, 403)
    const stats = await populateMockData(db)
    return c.json(stats)
  })

  app.delete('/api/dev/mock', (c) => {
    if (!settings.devMode) return c.json({ error: 'Dev mode not enabled' }, 403)
    const cleared = clearMockData(db)
    return c.json({ cleared })
  })

  // --- Config Linter API ---
  app.post('/api/lint', async (c) => {
    const body = await c.req.json().catch(() => ({}))
    const cwd = (body as Record<string, unknown>).cwd as string | undefined
    if (!cwd) return c.json({ error: 'cwd required' }, 400)

    // Validate: must be absolute path
    if (!cwd.startsWith('/')) return c.json({ error: 'cwd must be an absolute path' }, 400)

    // Defense-in-depth: reject paths outside $HOME
    const home = homedir()
    if (!cwd.startsWith(home + '/') && cwd !== home) {
      return c.json({ error: 'cwd must be within the home directory' }, 400)
    }

    // Validate: must exist as a directory
    try {
      const s = await stat(cwd)
      if (!s.isDirectory()) return c.json({ error: 'cwd is not a directory' }, 400)
    } catch {
      return c.json({ error: 'cwd does not exist' }, 400)
    }

    const result = await handleLintConfig({ cwd })
    return c.json(result)
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
