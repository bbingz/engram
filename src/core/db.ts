// src/core/db.ts
import BetterSqlite3 from 'better-sqlite3'
import type { SessionInfo, SourceName } from '../adapters/types.js'

export interface ListSessionsOptions {
  source?: SourceName
  sources?: string[]
  project?: string
  projects?: string[]
  since?: string
  until?: string
  limit?: number
  offset?: number
  agents?: 'hide' | 'only'  // hide = exclude agents, only = agents only
}

export interface FtsMatch {
  sessionId: string
  content: string
  rank: number
}

export class Database {
  private db: BetterSqlite3.Database

  constructor(dbPath: string) {
    this.db = new BetterSqlite3(dbPath)
    this.db.pragma('journal_mode = WAL')
    this.db.pragma('foreign_keys = ON')
    this.migrate()
  }

  private migrate(): void {
    // Add agent_role column if it doesn't exist (migration for existing DBs)
    const cols = this.db.prepare("PRAGMA table_info(sessions)").all() as { name: string }[]
    if (cols.length > 0) {
      const colNames = new Set(cols.map(c => c.name))
      if (!colNames.has('agent_role')) this.db.exec("ALTER TABLE sessions ADD COLUMN agent_role TEXT")
      if (!colNames.has('hidden_at')) this.db.exec("ALTER TABLE sessions ADD COLUMN hidden_at TEXT")
      if (!colNames.has('custom_name')) this.db.exec("ALTER TABLE sessions ADD COLUMN custom_name TEXT")
      if (!colNames.has('origin')) this.db.exec("ALTER TABLE sessions ADD COLUMN origin TEXT DEFAULT 'local'")
    }

    this.db.exec(`
      CREATE TABLE IF NOT EXISTS sessions (
        id TEXT PRIMARY KEY,
        source TEXT NOT NULL,
        start_time TEXT NOT NULL,
        end_time TEXT,
        cwd TEXT NOT NULL DEFAULT '',
        project TEXT,
        model TEXT,
        message_count INTEGER NOT NULL DEFAULT 0,
        user_message_count INTEGER NOT NULL DEFAULT 0,
        summary TEXT,
        file_path TEXT NOT NULL,
        size_bytes INTEGER NOT NULL DEFAULT 0,
        indexed_at TEXT NOT NULL DEFAULT (datetime('now')),
        agent_role TEXT,
        hidden_at TEXT,
        custom_name TEXT,
        origin TEXT DEFAULT 'local'
      );

      CREATE INDEX IF NOT EXISTS idx_sessions_source ON sessions(source);
      CREATE INDEX IF NOT EXISTS idx_sessions_start_time ON sessions(start_time);
      CREATE INDEX IF NOT EXISTS idx_sessions_cwd ON sessions(cwd);
      CREATE INDEX IF NOT EXISTS idx_sessions_file_path ON sessions(file_path);
      CREATE INDEX IF NOT EXISTS idx_sessions_agent_role ON sessions(agent_role);

      CREATE VIRTUAL TABLE IF NOT EXISTS sessions_fts USING fts5(
        session_id UNINDEXED,
        content,
        tokenize='trigram case_sensitive 0'
      );

      CREATE TABLE IF NOT EXISTS sync_state (
        peer_name TEXT PRIMARY KEY,
        last_sync_time TEXT NOT NULL
      );
    `)
  }

  upsertSession(session: SessionInfo): void {
    this.db.prepare(`
      INSERT INTO sessions (id, source, start_time, end_time, cwd, project, model,
        message_count, user_message_count, summary, file_path, size_bytes, indexed_at, agent_role, origin)
      VALUES (@id, @source, @startTime, @endTime, @cwd, @project, @model,
        @messageCount, @userMessageCount, @summary, @filePath, @sizeBytes, datetime('now'), @agentRole, @origin)
      ON CONFLICT(id) DO UPDATE SET
        source = excluded.source,
        model = excluded.model,
        end_time = excluded.end_time,
        message_count = excluded.message_count,
        user_message_count = excluded.user_message_count,
        summary = excluded.summary,
        size_bytes = excluded.size_bytes,
        indexed_at = excluded.indexed_at,
        agent_role = excluded.agent_role,
        origin = excluded.origin
    `).run({
      id: session.id,
      source: session.source,
      startTime: session.startTime,
      endTime: session.endTime ?? null,
      cwd: session.cwd,
      project: session.project ?? null,
      model: session.model ?? null,
      messageCount: session.messageCount,
      userMessageCount: session.userMessageCount,
      summary: session.summary ?? null,
      filePath: session.filePath,
      sizeBytes: session.sizeBytes,
      agentRole: session.agentRole ?? null,
      origin: session.origin ?? 'local',
    })
  }

  getSession(id: string): SessionInfo | null {
    const row = this.db.prepare('SELECT * FROM sessions WHERE id = ?').get(id) as Record<string, unknown> | undefined
    return row ? this.rowToSession(row) : null
  }

  listSessions(opts: ListSessionsOptions = {}): SessionInfo[] {
    const conditions: string[] = ['hidden_at IS NULL']
    const params: Record<string, unknown> = {}

    this.applyFilters(conditions, params, opts)

    const where = `WHERE ${conditions.join(' AND ')}`
    const limit = opts.limit ?? 20
    const offset = opts.offset ?? 0

    const rows = this.db.prepare(`
      SELECT * FROM sessions ${where}
      ORDER BY start_time DESC
      LIMIT @limit OFFSET @offset
    `).all({ ...params, limit, offset }) as Record<string, unknown>[]

    return rows.map(r => this.rowToSession(r))
  }

  listSessionsSince(since: string, limit = 100): SessionInfo[] {
    const rows = this.db.prepare(`
      SELECT * FROM sessions
      WHERE indexed_at > @since AND hidden_at IS NULL
      ORDER BY indexed_at ASC
      LIMIT @limit
    `).all({ since, limit }) as Record<string, unknown>[]
    return rows.map(r => this.rowToSession(r))
  }

  indexSessionContent(sessionId: string, messages: { role: string; content: string }[]): void {
    const deleteStmt = this.db.prepare('DELETE FROM sessions_fts WHERE session_id = ?')
    const insertStmt = this.db.prepare('INSERT INTO sessions_fts(session_id, content) VALUES (?, ?)')

    const transaction = this.db.transaction(() => {
      deleteStmt.run(sessionId)
      for (const msg of messages) {
        if (msg.role === 'user' && msg.content.trim()) {
          insertStmt.run(sessionId, msg.content)
        }
      }
    })
    transaction()
  }

  searchSessions(query: string, limit = 20): FtsMatch[] {
    return this.db.prepare(`
      SELECT f.session_id as sessionId, f.content, f.rank
      FROM sessions_fts f
      JOIN sessions s ON s.id = f.session_id
      WHERE sessions_fts MATCH ? AND s.hidden_at IS NULL
      ORDER BY f.rank
      LIMIT ?
    `).all(query, limit) as FtsMatch[]
  }

  deleteSession(id: string): void {
    this.db.prepare('DELETE FROM sessions WHERE id = ?').run(id)
    this.db.prepare('DELETE FROM sessions_fts WHERE session_id = ?').run(id)
  }

  isIndexed(filePath: string, sizeBytes: number): boolean {
    // Also returns true for hidden sessions with unchanged size (keeps them hidden)
    const row = this.db.prepare(
      'SELECT id FROM sessions WHERE file_path = ? AND size_bytes = ?'
    ).get(filePath, sizeBytes)
    return row !== undefined
  }

  countSessions(opts: Pick<ListSessionsOptions, 'source' | 'sources' | 'project' | 'projects' | 'agents'> = {}): number {
    const conditions: string[] = ['hidden_at IS NULL']
    const params: Record<string, unknown> = {}
    this.applyFilters(conditions, params, opts)
    return (this.db.prepare(`SELECT COUNT(*) as n FROM sessions WHERE ${conditions.join(' AND ')}`).get(params) as { n: number }).n
  }

  listSources(): string[] {
    const rows = this.db.prepare(
      'SELECT DISTINCT source FROM sessions WHERE hidden_at IS NULL ORDER BY source'
    ).all() as { source: string }[]
    return rows.map(r => r.source)
  }

  listProjects(): string[] {
    const rows = this.db.prepare(
      'SELECT DISTINCT project FROM sessions WHERE hidden_at IS NULL AND project IS NOT NULL ORDER BY project'
    ).all() as { project: string }[]
    return rows.map(r => r.project)
  }

  updateSessionSummary(id: string, summary: string): void {
    this.db.prepare('UPDATE sessions SET summary = ? WHERE id = ?').run(summary, id)
  }

  getFtsContent(sessionId: string): string[] {
    const rows = this.db.prepare(
      'SELECT content FROM sessions_fts WHERE session_id = ?'
    ).all(sessionId) as { content: string }[]
    return rows.map(r => r.content)
  }

  getRawDb(): BetterSqlite3.Database {
    return this.db
  }

  getSyncTime(peerName: string): string | null {
    const row = this.db.prepare(
      'SELECT last_sync_time FROM sync_state WHERE peer_name = ?'
    ).get(peerName) as { last_sync_time: string } | undefined
    return row?.last_sync_time ?? null
  }

  setSyncTime(peerName: string, time: string): void {
    this.db.prepare(
      'INSERT INTO sync_state (peer_name, last_sync_time) VALUES (?, ?) ON CONFLICT(peer_name) DO UPDATE SET last_sync_time = excluded.last_sync_time'
    ).run(peerName, time)
  }

  statsGroupBy(groupBy: string, since?: string, until?: string): { key: string; sessionCount: number; messageCount: number; userMessageCount: number }[] {
    let groupExpr: string
    if (groupBy === 'project') groupExpr = "COALESCE(project, '(unknown)')"
    else if (groupBy === 'day') groupExpr = "date(start_time, 'localtime')"
    else if (groupBy === 'week') groupExpr = "date(start_time, 'localtime', 'weekday 0', '-6 days')"
    else groupExpr = 'source'

    const conditions: string[] = ['hidden_at IS NULL']
    const params: Record<string, unknown> = {}
    if (since) { conditions.push('start_time >= @since'); params.since = since }
    if (until) { conditions.push('start_time <= @until'); params.until = until }
    const where = `WHERE ${conditions.join(' AND ')}`

    return this.db.prepare(`
      SELECT ${groupExpr} as key,
        COUNT(*) as sessionCount,
        SUM(message_count) as messageCount,
        SUM(user_message_count) as userMessageCount
      FROM sessions ${where}
      GROUP BY ${groupExpr}
      ORDER BY sessionCount DESC
    `).all(params) as { key: string; sessionCount: number; messageCount: number; userMessageCount: number }[]
  }

  close(): void {
    this.db.close()
  }

  private applyFilters(conditions: string[], params: Record<string, unknown>, opts: Pick<ListSessionsOptions, 'source' | 'sources' | 'project' | 'projects' | 'since' | 'until' | 'agents'>): void {
    const effectiveSources = opts.sources?.length ? opts.sources : opts.source ? [opts.source] : []
    if (effectiveSources.length === 1) {
      conditions.push('source = @source'); params.source = effectiveSources[0]
    } else if (effectiveSources.length > 1) {
      const placeholders = effectiveSources.map((s, i) => { params[`s${i}`] = s; return `@s${i}` })
      conditions.push(`source IN (${placeholders.join(',')})`)
    }
    const effectiveProjects = opts.projects?.length ? opts.projects : opts.project ? [opts.project] : []
    if (effectiveProjects.length === 1) {
      conditions.push('project = @project'); params.project = effectiveProjects[0]
    } else if (effectiveProjects.length > 1) {
      const placeholders = effectiveProjects.map((p, i) => { params[`p${i}`] = p; return `@p${i}` })
      conditions.push(`project IN (${placeholders.join(',')})`)
    }
    if ('since' in opts && opts.since) { conditions.push('start_time >= @since'); params.since = opts.since }
    if ('until' in opts && opts.until) { conditions.push('start_time <= @until'); params.until = opts.until }
    if (opts.agents === 'hide') {
      conditions.push("agent_role IS NULL AND file_path NOT LIKE '%/subagents/%'")
    } else if (opts.agents === 'only') {
      conditions.push("(agent_role IS NOT NULL OR file_path LIKE '%/subagents/%')")
    }
  }

  private rowToSession(row: Record<string, unknown>): SessionInfo {
    return {
      id: row.id as string,
      source: row.source as SessionInfo['source'],
      startTime: row.start_time as string,
      endTime: row.end_time as string | undefined,
      cwd: row.cwd as string,
      project: row.project as string | undefined,
      model: row.model as string | undefined,
      messageCount: row.message_count as number,
      userMessageCount: row.user_message_count as number,
      summary: row.summary as string | undefined,
      filePath: row.file_path as string,
      sizeBytes: row.size_bytes as number,
      agentRole: row.agent_role as string | undefined,
      origin: row.origin as string | undefined,
    }
  }
}
