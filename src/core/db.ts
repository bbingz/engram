// src/core/db.ts
import BetterSqlite3 from 'better-sqlite3'
import type { SessionInfo, SourceName } from '../adapters/types.js'
import type {
  AuthoritativeSessionSnapshot,
  IndexJobKind,
  IndexJobStatus,
  PersistedIndexJob,
  SessionLocalState,
  SyncCursor,
} from './session-snapshot.js'

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

export interface FtsSearchResult {
  sessionId: string
  snippet: string
  rank: number
}

export interface StatsGroup {
  key: string
  sessionCount: number
  messageCount: number
  userMessageCount: number
  assistantMessageCount: number
  toolMessageCount: number
}

// Base noise filters (always applied when agents='hide')
const NOISE_FILTER_BASE = [
  "agent_role IS NULL AND file_path NOT LIKE '%/subagents/%'",
  'message_count > 1',
]

// Optional noise filters — controlled by settings, default on
const NOISE_FILTER_USAGE = "(summary IS NULL OR summary NOT LIKE '%/usage%')"
const NOISE_FILTER_EMPTY = "(summary IS NULL OR length(trim(summary)) >= 10 OR message_count > 3)"
const NOISE_FILTER_AUTO_SUMMARY = "(summary IS NULL OR summary NOT LIKE '%Generate a short, clear title%')"

export interface NoiseFilterSettings {
  hideUsageSessions?: boolean   // default: true
  hideEmptySessions?: boolean   // default: true
  hideAutoSummary?: boolean     // default: true
}

/** Build noise filter SQL conditions based on settings */
export function buildNoiseFilters(settings: NoiseFilterSettings = {}): string[] {
  const filters = [...NOISE_FILTER_BASE]
  if (settings.hideUsageSessions !== false) filters.push(NOISE_FILTER_USAGE)
  if (settings.hideEmptySessions !== false) filters.push(NOISE_FILTER_EMPTY)
  if (settings.hideAutoSummary !== false) filters.push(NOISE_FILTER_AUTO_SUMMARY)
  return filters
}

// Default for backward compat — uses all filters
const NOISE_FILTER_SQL = buildNoiseFilters()

export function isNoiseSession(session: { agentRole?: string; filePath: string; messageCount: number; summary?: string }, settings: NoiseFilterSettings = {}): boolean {
  if (session.agentRole || session.filePath.includes('/subagents/')) return true
  if (session.messageCount <= 1) return true
  if (settings.hideUsageSessions !== false && session.summary?.includes('/usage')) return true
  if (settings.hideEmptySessions !== false && session.summary != null && session.summary.trim().length < 10 && session.messageCount <= 3) return true
  if (settings.hideAutoSummary !== false && session.summary?.includes('Generate a short, clear title')) return true
  return false
}

export interface SearchFilters {
  source?: string
  project?: string
  since?: string
}

function buildIndexJobId(sessionId: string, targetSyncVersion: number, jobKind: IndexJobKind): string {
  return `${sessionId}:${targetSyncVersion}:${jobKind}`
}

export class Database {
  private db: BetterSqlite3.Database
  noiseSettings: NoiseFilterSettings = {}

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
      if (!colNames.has('assistant_message_count')) this.db.exec("ALTER TABLE sessions ADD COLUMN assistant_message_count INTEGER NOT NULL DEFAULT 0")
      if (!colNames.has('system_message_count')) this.db.exec("ALTER TABLE sessions ADD COLUMN system_message_count INTEGER NOT NULL DEFAULT 0")
      if (!colNames.has('tool_message_count')) this.db.exec("ALTER TABLE sessions ADD COLUMN tool_message_count INTEGER NOT NULL DEFAULT 0")
      if (!colNames.has('summary_message_count')) this.db.exec("ALTER TABLE sessions ADD COLUMN summary_message_count INTEGER")
      if (!colNames.has('authoritative_node')) this.db.exec("ALTER TABLE sessions ADD COLUMN authoritative_node TEXT")
      if (!colNames.has('source_locator')) this.db.exec("ALTER TABLE sessions ADD COLUMN source_locator TEXT")
      if (!colNames.has('sync_version')) this.db.exec("ALTER TABLE sessions ADD COLUMN sync_version INTEGER NOT NULL DEFAULT 0")
      if (!colNames.has('snapshot_hash')) this.db.exec("ALTER TABLE sessions ADD COLUMN snapshot_hash TEXT")
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
        assistant_message_count INTEGER NOT NULL DEFAULT 0,
        tool_message_count INTEGER NOT NULL DEFAULT 0,
        system_message_count INTEGER NOT NULL DEFAULT 0,
        summary TEXT,
        summary_message_count INTEGER,
        file_path TEXT NOT NULL,
        size_bytes INTEGER NOT NULL DEFAULT 0,
        indexed_at TEXT NOT NULL DEFAULT (datetime('now')),
        agent_role TEXT,
        hidden_at TEXT,
        custom_name TEXT,
        origin TEXT DEFAULT 'local',
        authoritative_node TEXT,
        source_locator TEXT,
        sync_version INTEGER NOT NULL DEFAULT 0,
        snapshot_hash TEXT
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
        last_sync_time TEXT NOT NULL,
        last_sync_session_id TEXT
      );

      CREATE TABLE IF NOT EXISTS metadata (
        key TEXT PRIMARY KEY,
        value TEXT NOT NULL
      );

      CREATE TABLE IF NOT EXISTS project_aliases (
        alias TEXT NOT NULL,
        canonical TEXT NOT NULL,
        created_at TEXT NOT NULL DEFAULT (datetime('now')),
        PRIMARY KEY (alias, canonical)
      );

      CREATE TABLE IF NOT EXISTS session_local_state (
        session_id TEXT PRIMARY KEY REFERENCES sessions(id) ON DELETE CASCADE,
        hidden_at TEXT,
        custom_name TEXT,
        local_readable_path TEXT
      );

      CREATE TABLE IF NOT EXISTS session_index_jobs (
        id TEXT PRIMARY KEY,
        session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
        job_kind TEXT NOT NULL,
        target_sync_version INTEGER NOT NULL,
        status TEXT NOT NULL,
        retry_count INTEGER NOT NULL DEFAULT 0,
        last_error TEXT,
        created_at TEXT NOT NULL DEFAULT (datetime('now')),
        updated_at TEXT NOT NULL DEFAULT (datetime('now'))
      );

      CREATE INDEX IF NOT EXISTS idx_session_index_jobs_status ON session_index_jobs(status);
      CREATE INDEX IF NOT EXISTS idx_session_index_jobs_session_id ON session_index_jobs(session_id);
    `)

    const syncCols = this.db.prepare("PRAGMA table_info(sync_state)").all() as { name: string }[]
    const syncColNames = new Set(syncCols.map(c => c.name))
    if (syncCols.length > 0 && !syncColNames.has('last_sync_session_id')) {
      this.db.exec("ALTER TABLE sync_state ADD COLUMN last_sync_session_id TEXT")
    }

    // Migration: FTS v2 indexes user + assistant messages (v1 was user-only)
    // Reset size_bytes to force indexAll() to re-process all sessions for new FTS content
    const FTS_VERSION = '3'
    const ftsVersion = this.getMetadata('fts_version')
    if (ftsVersion !== FTS_VERSION) {
      this.db.exec('DELETE FROM sessions_fts')
      this.db.exec('UPDATE sessions SET size_bytes = 0')
      try { this.db.exec('DELETE FROM session_embeddings') } catch { /* table may not exist yet */ }
      try { this.db.exec('DELETE FROM vec_sessions') } catch { /* table may not exist yet */ }
      this.setMetadata('fts_version', FTS_VERSION)
    }

    this.runPostMigrationBackfill()
  }

  upsertSession(session: SessionInfo): void {
    this.db.prepare(`
      INSERT INTO sessions (id, source, start_time, end_time, cwd, project, model,
        message_count, user_message_count, assistant_message_count, tool_message_count, system_message_count,
        summary, file_path, size_bytes, indexed_at, agent_role, origin, authoritative_node, source_locator, sync_version, snapshot_hash)
      VALUES (@id, @source, @startTime, @endTime, @cwd, @project, @model,
        @messageCount, @userMessageCount, @assistantMessageCount, @toolMessageCount, @systemMessageCount,
        @summary, @filePath, @sizeBytes, datetime('now'), @agentRole, @origin, @authoritativeNode, @sourceLocator, 0, '')
      ON CONFLICT(id) DO UPDATE SET
        source = excluded.source,
        cwd = excluded.cwd,
        project = excluded.project,
        model = excluded.model,
        end_time = excluded.end_time,
        message_count = excluded.message_count,
        user_message_count = excluded.user_message_count,
        assistant_message_count = excluded.assistant_message_count,
        tool_message_count = excluded.tool_message_count,
        system_message_count = excluded.system_message_count,
        summary = excluded.summary,
        size_bytes = excluded.size_bytes,
        indexed_at = excluded.indexed_at,
        agent_role = excluded.agent_role,
        origin = excluded.origin,
        authoritative_node = COALESCE(sessions.authoritative_node, excluded.authoritative_node),
        source_locator = COALESCE(excluded.source_locator, sessions.source_locator)
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
      assistantMessageCount: session.assistantMessageCount,
      toolMessageCount: session.toolMessageCount,
      systemMessageCount: session.systemMessageCount,
      summary: session.summary ?? null,
      filePath: session.filePath,
      sizeBytes: session.sizeBytes,
      agentRole: session.agentRole ?? null,
      origin: session.origin ?? 'local',
      authoritativeNode: session.origin ?? 'local',
      sourceLocator: session.filePath,
    })
  }

  getSession(id: string): SessionInfo | null {
    const row = this.db.prepare(`
      SELECT s.*, ls.local_readable_path
      FROM sessions s
      LEFT JOIN session_local_state ls ON ls.session_id = s.id
      WHERE s.id = ?
    `).get(id) as Record<string, unknown> | undefined
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
      SELECT base.*, ls.local_readable_path
      FROM (
        SELECT * FROM sessions ${where}
        ORDER BY start_time DESC
        LIMIT @limit OFFSET @offset
      ) base
      LEFT JOIN session_local_state ls ON ls.session_id = base.id
      ORDER BY base.start_time DESC
    `).all({ ...params, limit, offset }) as Record<string, unknown>[]

    return rows.map(r => this.rowToSession(r))
  }

  listSessionsSince(since: string, limit = 100): SessionInfo[] {
    const rows = this.db.prepare(`
      SELECT s.*, ls.local_readable_path
      FROM sessions s
      LEFT JOIN session_local_state ls ON ls.session_id = s.id
      WHERE s.indexed_at > @since AND s.hidden_at IS NULL
      ORDER BY s.indexed_at ASC
      LIMIT @limit
    `).all({ since, limit }) as Record<string, unknown>[]
    return rows.map(r => this.rowToSession(r))
  }

  listSessionsAfterCursor(cursor: SyncCursor | null, limit = 100): AuthoritativeSessionSnapshot[] {
    const rows = cursor
      ? this.db.prepare(`
          SELECT *
          FROM sessions
          WHERE hidden_at IS NULL
            AND (
              indexed_at > @indexedAt
              OR (indexed_at = @indexedAt AND id > @sessionId)
            )
          ORDER BY indexed_at ASC, id ASC
          LIMIT @limit
        `).all({ indexedAt: cursor.indexedAt, sessionId: cursor.sessionId, limit }) as Record<string, unknown>[]
      : this.db.prepare(`
          SELECT *
          FROM sessions
          WHERE hidden_at IS NULL
          ORDER BY indexed_at ASC, id ASC
          LIMIT @limit
        `).all({ limit }) as Record<string, unknown>[]

    return rows.map(r => this.rowToAuthoritativeSnapshot(r))
  }

  indexSessionContent(sessionId: string, messages: { role: string; content: string }[], summary?: string): void {
    const deleteStmt = this.db.prepare('DELETE FROM sessions_fts WHERE session_id = ?')
    const insertStmt = this.db.prepare('INSERT INTO sessions_fts(session_id, content) VALUES (?, ?)')

    const transaction = this.db.transaction(() => {
      deleteStmt.run(sessionId)
      for (const msg of messages) {
        if ((msg.role === 'user' || msg.role === 'assistant') && msg.content.trim()) {
          insertStmt.run(sessionId, msg.content)
        }
      }
      if (summary?.trim()) {
        insertStmt.run(sessionId, summary)
      }
    })
    transaction()
  }

  searchSessions(query: string, limit = 20, filters?: SearchFilters): FtsSearchResult[] {
    const doSearch = (q: string): FtsSearchResult[] => {
      const conditions: string[] = ['sessions_fts MATCH @query', 's.hidden_at IS NULL']
      const params: Record<string, unknown> = { query: q, limit }

      if (filters?.source) {
        conditions.push('s.source = @source')
        params.source = filters.source
      }
      if (filters?.project) {
        const expanded = this.resolveProjectAliases([filters.project])
        if (expanded.length === 1) {
          conditions.push('s.project LIKE @project')
          params.project = `%${expanded[0]}%`
        } else {
          const clauses = expanded.map((p, i) => { params[`proj${i}`] = `%${p}%`; return `s.project LIKE @proj${i}` })
          conditions.push(`(${clauses.join(' OR ')})`)
        }
      }
      if (filters?.since) {
        conditions.push('s.start_time >= @since')
        params.since = filters.since
      }

      const where = conditions.join(' AND ')
      return this.db.prepare(`
        SELECT
          f.session_id AS sessionId,
          snippet(sessions_fts, 1, '<mark>', '</mark>', '…', 32) AS snippet,
          f.rank
        FROM sessions_fts f
        JOIN sessions s ON s.id = f.session_id
        WHERE ${where}
        ORDER BY f.rank
        LIMIT @limit
      `).all(params) as FtsSearchResult[]
    }

    try {
      return doSearch(query)
    } catch {
      const escaped = '"' + query.replace(/"/g, '""') + '"'
      return doSearch(escaped)
    }
  }

  deleteSession(id: string): void {
    this.db.prepare('DELETE FROM sessions WHERE id = ?').run(id)
    this.db.prepare('DELETE FROM sessions_fts WHERE session_id = ?').run(id)
  }

  isIndexed(filePath: string, sizeBytes: number): boolean {
    // Also returns true for hidden sessions with unchanged size (keeps them hidden)
    const row = this.db.prepare(
      'SELECT id FROM sessions WHERE (file_path = ? OR source_locator = ?) AND size_bytes = ?'
    ).get(filePath, filePath, sizeBytes)
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

  getSourceStats(): { source: string; sessionCount: number; latestIndexed: string; dailyCounts: number[] }[] {
    const sourceRows = this.db.prepare(`
      SELECT source, COUNT(*) as count, MAX(indexed_at) as latest_indexed
      FROM sessions WHERE hidden_at IS NULL
      GROUP BY source ORDER BY count DESC
    `).all() as { source: string; count: number; latest_indexed: string }[]

    if (sourceRows.length === 0) return []

    const dailyRows = this.db.prepare(`
      SELECT source, date(start_time) as day, COUNT(*) as count
      FROM sessions
      WHERE hidden_at IS NULL AND start_time >= date('now', '-7 days')
      GROUP BY source, date(start_time)
    `).all() as { source: string; day: string; count: number }[]

    const days: string[] = []
    for (let i = 6; i >= 0; i--) {
      const d = new Date(Date.now() - i * 86400000)
      days.push(d.toISOString().slice(0, 10))
    }

    const dailyMap = new Map<string, Map<string, number>>()
    for (const row of dailyRows) {
      if (!dailyMap.has(row.source)) dailyMap.set(row.source, new Map())
      dailyMap.get(row.source)!.set(row.day, row.count)
    }

    return sourceRows.map(row => ({
      source: row.source,
      sessionCount: row.count,
      latestIndexed: row.latest_indexed ?? '',
      dailyCounts: days.map(d => dailyMap.get(row.source)?.get(d) ?? 0),
    }))
  }

  listProjects(): string[] {
    const rows = this.db.prepare(
      'SELECT DISTINCT project FROM sessions WHERE hidden_at IS NULL AND project IS NOT NULL ORDER BY project'
    ).all() as { project: string }[]
    return rows.map(r => r.project)
  }

  updateSessionSummary(id: string, summary: string, messageCount?: number): void {
    if (messageCount !== undefined) {
      this.db.prepare('UPDATE sessions SET summary = ?, summary_message_count = ? WHERE id = ?').run(summary, messageCount, id)
    } else {
      this.db.prepare('UPDATE sessions SET summary = ? WHERE id = ?').run(summary, id)
    }
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

  runPostMigrationBackfill(): void {
    // Incremental: only backfill sessions not yet in session_local_state
    // and sessions missing authoritative_node. Safe to run every startup.
    const inserted = this.db.prepare(`
      INSERT INTO session_local_state (session_id, hidden_at, custom_name, local_readable_path)
      SELECT id, hidden_at, custom_name, file_path
      FROM sessions
      WHERE id NOT IN (SELECT session_id FROM session_local_state)
    `).run()

    const updated = this.db.prepare(`
      UPDATE sessions
      SET
        authoritative_node = COALESCE(authoritative_node, origin, 'local'),
        source_locator = COALESCE(source_locator, file_path),
        sync_version = COALESCE(sync_version, 0),
        snapshot_hash = COALESCE(snapshot_hash, '')
      WHERE authoritative_node IS NULL
    `).run()

    // Only does work when there are unmigrated rows — effectively O(0) on subsequent starts
  }

  getSyncTime(peerName: string): string | null {
    const row = this.db.prepare(
      'SELECT last_sync_time FROM sync_state WHERE peer_name = ?'
    ).get(peerName) as { last_sync_time: string } | undefined
    return row?.last_sync_time ?? null
  }

  setSyncTime(peerName: string, time: string): void {
    this.db.prepare(
      'INSERT INTO sync_state (peer_name, last_sync_time, last_sync_session_id) VALUES (?, ?, ?) ON CONFLICT(peer_name) DO UPDATE SET last_sync_time = excluded.last_sync_time'
    ).run(peerName, time, null)
  }

  getSyncCursor(peerName: string): SyncCursor | null {
    const row = this.db.prepare(
      'SELECT last_sync_time, last_sync_session_id FROM sync_state WHERE peer_name = ?'
    ).get(peerName) as { last_sync_time: string; last_sync_session_id: string | null } | undefined
    if (!row?.last_sync_time || !row.last_sync_session_id) return null
    return {
      indexedAt: row.last_sync_time,
      sessionId: row.last_sync_session_id,
    }
  }

  setSyncCursor(peerName: string, cursor: SyncCursor): void {
    this.db.prepare(`
      INSERT INTO sync_state (peer_name, last_sync_time, last_sync_session_id)
      VALUES (@peerName, @indexedAt, @sessionId)
      ON CONFLICT(peer_name) DO UPDATE SET
        last_sync_time = excluded.last_sync_time,
        last_sync_session_id = excluded.last_sync_session_id
    `).run({
      peerName,
      indexedAt: cursor.indexedAt,
      sessionId: cursor.sessionId,
    })
  }

  getAuthoritativeSnapshot(id: string): AuthoritativeSessionSnapshot | null {
    const row = this.db.prepare('SELECT * FROM sessions WHERE id = ?').get(id) as Record<string, unknown> | undefined
    return row ? this.rowToAuthoritativeSnapshot(row) : null
  }

  upsertAuthoritativeSnapshot(snapshot: AuthoritativeSessionSnapshot): void {
    const localReadablePath = this.getLocalState(snapshot.id)?.localReadablePath ?? ''
    this.db.prepare(`
      INSERT INTO sessions (
        id, source, start_time, end_time, cwd, project, model,
        message_count, user_message_count, assistant_message_count, tool_message_count, system_message_count,
        summary, summary_message_count, file_path, size_bytes, indexed_at, origin,
        authoritative_node, source_locator, sync_version, snapshot_hash
      ) VALUES (
        @id, @source, @startTime, @endTime, @cwd, @project, @model,
        @messageCount, @userMessageCount, @assistantMessageCount, @toolMessageCount, @systemMessageCount,
        @summary, @summaryMessageCount, @legacyFilePath, @sizeBytes, @indexedAt, @origin,
        @authoritativeNode, @sourceLocator, @syncVersion, @snapshotHash
      )
      ON CONFLICT(id) DO UPDATE SET
        source = excluded.source,
        start_time = excluded.start_time,
        end_time = excluded.end_time,
        cwd = excluded.cwd,
        project = COALESCE(excluded.project, sessions.project),
        model = COALESCE(excluded.model, sessions.model),
        message_count = excluded.message_count,
        user_message_count = excluded.user_message_count,
        assistant_message_count = excluded.assistant_message_count,
        tool_message_count = excluded.tool_message_count,
        system_message_count = excluded.system_message_count,
        summary = COALESCE(excluded.summary, sessions.summary),
        summary_message_count = COALESCE(excluded.summary_message_count, sessions.summary_message_count),
        size_bytes = excluded.size_bytes,
        indexed_at = excluded.indexed_at,
        origin = excluded.origin,
        authoritative_node = excluded.authoritative_node,
        source_locator = excluded.source_locator,
        sync_version = excluded.sync_version,
        snapshot_hash = excluded.snapshot_hash
    `).run({
      id: snapshot.id,
      source: snapshot.source,
      startTime: snapshot.startTime,
      endTime: snapshot.endTime ?? null,
      cwd: snapshot.cwd,
      project: snapshot.project ?? null,
      model: snapshot.model ?? null,
      messageCount: snapshot.messageCount,
      userMessageCount: snapshot.userMessageCount,
      assistantMessageCount: snapshot.assistantMessageCount,
      toolMessageCount: snapshot.toolMessageCount,
      systemMessageCount: snapshot.systemMessageCount,
      summary: snapshot.summary ?? null,
      summaryMessageCount: snapshot.summaryMessageCount ?? null,
      legacyFilePath: localReadablePath,
      sizeBytes: snapshot.sizeBytes ?? 0,
      indexedAt: snapshot.indexedAt,
      origin: snapshot.origin ?? snapshot.authoritativeNode,
      authoritativeNode: snapshot.authoritativeNode,
      sourceLocator: snapshot.sourceLocator,
      syncVersion: snapshot.syncVersion,
      snapshotHash: snapshot.snapshotHash,
    })
  }

  getLocalState(sessionId: string): SessionLocalState | null {
    const row = this.db.prepare(`
      SELECT session_id, hidden_at, custom_name, local_readable_path
      FROM session_local_state
      WHERE session_id = ?
    `).get(sessionId) as {
      session_id: string
      hidden_at: string | null
      custom_name: string | null
      local_readable_path: string | null
    } | undefined
    if (!row) return null
    return {
      sessionId: row.session_id,
      hiddenAt: row.hidden_at ?? undefined,
      customName: row.custom_name ?? undefined,
      localReadablePath: row.local_readable_path ?? undefined,
    }
  }

  setLocalReadablePath(sessionId: string, localReadablePath: string | null): void {
    this.db.prepare(`
      INSERT INTO session_local_state (session_id, local_readable_path)
      VALUES (?, ?)
      ON CONFLICT(session_id) DO UPDATE SET local_readable_path = excluded.local_readable_path
    `).run(sessionId, localReadablePath)
  }

  insertIndexJobs(sessionId: string, targetSyncVersion: number, jobKinds: IndexJobKind[]): void {
    const insert = this.db.prepare(`
      INSERT INTO session_index_jobs (
        id, session_id, job_kind, target_sync_version, status, retry_count, last_error, created_at, updated_at
      ) VALUES (
        @id, @sessionId, @jobKind, @targetSyncVersion, 'pending', 0, NULL, datetime('now'), datetime('now')
      )
      ON CONFLICT(id) DO UPDATE SET
        status = 'pending',
        last_error = NULL,
        updated_at = datetime('now')
    `)
    const tx = this.db.transaction((kinds: IndexJobKind[]) => {
      for (const jobKind of kinds) {
        insert.run({
          id: buildIndexJobId(sessionId, targetSyncVersion, jobKind),
          sessionId,
          jobKind,
          targetSyncVersion,
        })
      }
    })
    tx(jobKinds)
  }

  takeRecoverableIndexJobs(limit: number): PersistedIndexJob[] {
    const rows = this.db.prepare(`
      SELECT id, session_id, job_kind, target_sync_version, status, retry_count, last_error, created_at, updated_at
      FROM session_index_jobs
      WHERE status IN ('pending', 'failed_retryable')
      ORDER BY CASE job_kind WHEN 'fts' THEN 0 ELSE 1 END, created_at, id
      LIMIT @limit
    `).all({ limit }) as Array<{
      id: string
      session_id: string
      job_kind: IndexJobKind
      target_sync_version: number
      status: IndexJobStatus
      retry_count: number
      last_error: string | null
      created_at: string
      updated_at: string
    }>
    return rows.map(row => ({
      id: row.id,
      sessionId: row.session_id,
      jobKind: row.job_kind,
      targetSyncVersion: row.target_sync_version,
      status: row.status,
      retryCount: row.retry_count,
      lastError: row.last_error ?? undefined,
      createdAt: row.created_at,
      updatedAt: row.updated_at,
    }))
  }

  listIndexJobs(sessionId: string): PersistedIndexJob[] {
    const rows = this.db.prepare(`
      SELECT id, session_id, job_kind, target_sync_version, status, retry_count, last_error, created_at, updated_at
      FROM session_index_jobs
      WHERE session_id = ?
      ORDER BY created_at, id
    `).all(sessionId) as Array<{
      id: string
      session_id: string
      job_kind: IndexJobKind
      target_sync_version: number
      status: IndexJobStatus
      retry_count: number
      last_error: string | null
      created_at: string
      updated_at: string
    }>
    return rows.map(row => ({
      id: row.id,
      sessionId: row.session_id,
      jobKind: row.job_kind,
      targetSyncVersion: row.target_sync_version,
      status: row.status,
      retryCount: row.retry_count,
      lastError: row.last_error ?? undefined,
      createdAt: row.created_at,
      updatedAt: row.updated_at,
    }))
  }

  markIndexJobCompleted(id: string): void {
    this.db.prepare(`
      UPDATE session_index_jobs
      SET status = 'completed', last_error = NULL, updated_at = datetime('now')
      WHERE id = ?
    `).run(id)
  }

  markIndexJobNotApplicable(id: string): void {
    this.db.prepare(`
      UPDATE session_index_jobs
      SET status = 'not_applicable', last_error = NULL, updated_at = datetime('now')
      WHERE id = ?
    `).run(id)
  }

  markIndexJobRetryableFailure(id: string, error: string): void {
    this.db.prepare(`
      UPDATE session_index_jobs
      SET status = 'failed_retryable',
          retry_count = retry_count + 1,
          last_error = ?,
          updated_at = datetime('now')
      WHERE id = ?
    `).run(error, id)
  }

  replaceFtsContent(sessionId: string, contents: string[]): void {
    const deleteStmt = this.db.prepare('DELETE FROM sessions_fts WHERE session_id = ?')
    const insertStmt = this.db.prepare('INSERT INTO sessions_fts(session_id, content) VALUES (?, ?)')
    const tx = this.db.transaction(() => {
      deleteStmt.run(sessionId)
      for (const content of contents) {
        if (content.trim()) insertStmt.run(sessionId, content)
      }
    })
    tx()
  }

  needsCountBackfill(): string[] {
    const rows = this.db.prepare(
      "SELECT id FROM sessions WHERE assistant_message_count = 0 AND message_count > 0 AND hidden_at IS NULL"
    ).all() as { id: string }[]
    return rows.map(r => r.id)
  }

  statsGroupBy(groupBy: string, since?: string, until?: string, opts?: { excludeNoise?: boolean }): StatsGroup[] {
    let groupExpr: string
    if (groupBy === 'project') groupExpr = "COALESCE(project, '(unknown)')"
    else if (groupBy === 'day') groupExpr = "date(start_time, 'localtime')"
    else if (groupBy === 'week') groupExpr = "date(start_time, 'localtime', 'weekday 0', '-6 days')"
    else groupExpr = 'source'

    const conditions: string[] = ['hidden_at IS NULL']
    const params: Record<string, unknown> = {}
    if (since) { conditions.push('start_time >= @since'); params.since = since }
    if (until) { conditions.push('start_time <= @until'); params.until = until }
    if (opts?.excludeNoise) {
      conditions.push(...buildNoiseFilters(this.noiseSettings))
    }
    const where = `WHERE ${conditions.join(' AND ')}`

    // Exclude /usage sessions from user message count even when showing all sessions
    const userMsgExpr = opts?.excludeNoise
      ? 'SUM(user_message_count)'
      : "SUM(CASE WHEN summary LIKE '%/usage%' OR message_count <= 1 THEN 0 ELSE user_message_count END)"

    return this.db.prepare(`
      SELECT ${groupExpr} as key,
        COUNT(*) as sessionCount,
        SUM(message_count) as messageCount,
        ${userMsgExpr} as userMessageCount,
        SUM(assistant_message_count) as assistantMessageCount,
        SUM(tool_message_count) as toolMessageCount
      FROM sessions ${where}
      GROUP BY ${groupExpr}
      ORDER BY sessionCount DESC
    `).all(params) as StatsGroup[]
  }

  close(): void {
    this.db.close()
  }

  getMetadata(key: string): string | null {
    const row = this.db.prepare('SELECT value FROM metadata WHERE key = ?').get(key) as { value: string } | undefined
    return row?.value ?? null
  }

  setMetadata(key: string, value: string): void {
    this.db.prepare(
      'INSERT INTO metadata (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value'
    ).run(key, value)
  }

  // --- Project aliases ---

  resolveProjectAliases(projects: string[]): string[] {
    if (projects.length === 0) return projects
    const placeholders = projects.map((_, i) => `?`).join(',')
    const rows = this.db.prepare(`
      SELECT DISTINCT alias AS name FROM project_aliases WHERE canonical IN (${placeholders})
      UNION
      SELECT DISTINCT canonical AS name FROM project_aliases WHERE alias IN (${placeholders})
    `).all(...projects, ...projects) as { name: string }[]
    const all = new Set(projects)
    for (const r of rows) all.add(r.name)
    return [...all]
  }

  addProjectAlias(alias: string, canonical: string): void {
    this.db.prepare('INSERT OR IGNORE INTO project_aliases (alias, canonical) VALUES (?, ?)').run(alias, canonical)
  }

  removeProjectAlias(alias: string, canonical: string): void {
    this.db.prepare('DELETE FROM project_aliases WHERE alias = ? AND canonical = ?').run(alias, canonical)
  }

  listProjectAliases(): { alias: string; canonical: string }[] {
    return this.db.prepare('SELECT alias, canonical FROM project_aliases ORDER BY canonical, alias').all() as { alias: string; canonical: string }[]
  }

  private applyFilters(conditions: string[], params: Record<string, unknown>, opts: Pick<ListSessionsOptions, 'source' | 'sources' | 'project' | 'projects' | 'since' | 'until' | 'agents'>): void {
    const effectiveSources = opts.sources?.length ? opts.sources : opts.source ? [opts.source] : []
    if (effectiveSources.length === 1) {
      conditions.push('source = @source'); params.source = effectiveSources[0]
    } else if (effectiveSources.length > 1) {
      const placeholders = effectiveSources.map((s, i) => { params[`s${i}`] = s; return `@s${i}` })
      conditions.push(`source IN (${placeholders.join(',')})`)
    }
    const rawProjects = opts.projects?.length ? opts.projects : opts.project ? [opts.project] : []
    const effectiveProjects = rawProjects.length > 0 ? this.resolveProjectAliases(rawProjects) : rawProjects
    if (effectiveProjects.length === 1) {
      conditions.push('project = @project'); params.project = effectiveProjects[0]
    } else if (effectiveProjects.length > 1) {
      const placeholders = effectiveProjects.map((p, i) => { params[`p${i}`] = p; return `@p${i}` })
      conditions.push(`project IN (${placeholders.join(',')})`)
    }
    if ('since' in opts && opts.since) { conditions.push('start_time >= @since'); params.since = opts.since }
    if ('until' in opts && opts.until) { conditions.push('start_time <= @until'); params.until = opts.until }
    if (opts.agents === 'hide') {
      conditions.push(...buildNoiseFilters(this.noiseSettings))
    } else if (opts.agents === 'only') {
      conditions.push("(agent_role IS NOT NULL OR file_path LIKE '%/subagents/%')")
    }
  }

  // FTS optimization — merges internal b-tree segments for faster queries
  optimizeFts(): void {
    this.db.exec("INSERT INTO sessions_fts(sessions_fts) VALUES('optimize')")
  }

  // VACUUM if fragmentation exceeds threshold (percentage of freelist pages)
  vacuumIfNeeded(thresholdPct: number): boolean {
    const pageCount = (this.db.pragma('page_count') as { page_count: number }[])[0]?.page_count ?? 0
    const freeCount = (this.db.pragma('freelist_count') as { freelist_count: number }[])[0]?.freelist_count ?? 0
    if (pageCount === 0) return false
    const fragPct = (freeCount / pageCount) * 100
    if (fragPct > thresholdPct) {
      this.db.exec('VACUUM')
      return true
    }
    return false
  }

  // Remove duplicate file_path entries, keeping the most recently indexed one.
  // Skip empty/null file_path values — authoritative snapshots may have empty legacy paths.
  deduplicateFilePaths(): number {
    const result = this.db.prepare(`
      DELETE FROM sessions WHERE rowid NOT IN (
        SELECT MAX(rowid) FROM sessions GROUP BY file_path
      ) AND file_path IS NOT NULL AND file_path != ''
    `).run()
    return result.changes
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
      assistantMessageCount: (row.assistant_message_count as number) ?? 0,
      toolMessageCount: (row.tool_message_count as number) ?? 0,
      systemMessageCount: (row.system_message_count as number) ?? 0,
      summary: row.summary as string | undefined,
      filePath: (row.local_readable_path as string | undefined)
        ?? (row.source_locator as string | undefined)
        ?? (row.file_path as string),
      sizeBytes: row.size_bytes as number,
      indexedAt: row.indexed_at as string | undefined,
      agentRole: row.agent_role as string | undefined,
      origin: row.origin as string | undefined,
      summaryMessageCount: row.summary_message_count as number | undefined,
    }
  }

  private rowToAuthoritativeSnapshot(row: Record<string, unknown>): AuthoritativeSessionSnapshot {
    return {
      id: row.id as string,
      source: row.source as SourceName,
      authoritativeNode: (row.authoritative_node as string | null) ?? (row.origin as string | null) ?? 'local',
      syncVersion: (row.sync_version as number | null) ?? 0,
      snapshotHash: (row.snapshot_hash as string | null) ?? '',
      indexedAt: row.indexed_at as string,
      sourceLocator: ((row.source_locator as string | null) ?? (row.file_path as string | null) ?? '') as string,
      sizeBytes: (row.size_bytes as number | null) ?? 0,
      startTime: row.start_time as string,
      endTime: (row.end_time as string | null) ?? undefined,
      cwd: (row.cwd as string | null) ?? '',
      project: (row.project as string | null) ?? undefined,
      model: (row.model as string | null) ?? undefined,
      messageCount: (row.message_count as number | null) ?? 0,
      userMessageCount: (row.user_message_count as number | null) ?? 0,
      assistantMessageCount: (row.assistant_message_count as number | null) ?? 0,
      toolMessageCount: (row.tool_message_count as number | null) ?? 0,
      systemMessageCount: (row.system_message_count as number | null) ?? 0,
      summary: (row.summary as string | null) ?? undefined,
      summaryMessageCount: (row.summary_message_count as number | null) ?? undefined,
      origin: (row.origin as string | null) ?? undefined,
    }
  }
}
