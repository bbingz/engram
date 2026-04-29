// src/core/db/session-repo.ts — session CRUD + filtering
import type BetterSqlite3 from 'better-sqlite3';
import type { SessionInfo, SourceName } from '../../adapters/types.js';
import { getLocalTimeRange } from '../../utils/time.js';
import {
  isReadableSessionPath,
  pickReadableSessionPath,
} from '../session-path.js';
import { computeQualityScore } from '../session-scoring.js';
import type {
  AuthoritativeSessionSnapshot,
  SyncCursor,
} from '../session-snapshot.js';
import { setParentSession, validateParentLink } from './parent-link-repo.js';
import type { ListSessionsOptions, NoiseFilter } from './types.js';

export function buildTierFilter(filter: NoiseFilter = 'hide-skip'): string[] {
  if (filter === 'all') return [];
  if (filter === 'hide-noise')
    return ["(tier IS NULL OR tier NOT IN ('skip', 'lite'))"];
  return ["(tier IS NULL OR tier != 'skip')"];
}

/**
 * SQL fragment that hides orphan sessions (file has disappeared from source).
 * Pass includeOrphans=true in admin/GC contexts.
 */
export function buildOrphanFilter(includeOrphans?: boolean): string[] {
  if (includeOrphans) return [];
  return ['orphan_status IS NULL'];
}

export function isTierHidden(
  tier: string | null | undefined,
  filter: NoiseFilter = 'hide-skip',
): boolean {
  if (filter === 'all') return false;
  if (filter === 'hide-noise') return tier === 'skip' || tier === 'lite';
  return tier === 'skip';
}

function nonEmptyString(value: unknown): string | undefined {
  return typeof value === 'string' && value.length > 0 ? value : undefined;
}

function rowToSession(row: Record<string, unknown>): SessionInfo {
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
    filePath: pickReadableSessionPath(
      nonEmptyString(row.local_readable_path),
      nonEmptyString(row.file_path),
      nonEmptyString(row.source_locator),
    ),
    sizeBytes: row.size_bytes as number,
    indexedAt: row.indexed_at as string | undefined,
    agentRole: row.agent_role as string | undefined,
    origin: row.origin as string | undefined,
    summaryMessageCount: row.summary_message_count as number | undefined,
    tier: row.tier as string | undefined,
    qualityScore: (row.quality_score as number | null) ?? 0,
    parentSessionId: row.parent_session_id as string | undefined,
    suggestedParentId: row.suggested_parent_id as string | undefined,
  };
}

function rowToAuthoritativeSnapshot(
  row: Record<string, unknown>,
): AuthoritativeSessionSnapshot {
  return {
    id: row.id as string,
    source: row.source as SourceName,
    authoritativeNode:
      (row.authoritative_node as string | null) ??
      (row.origin as string | null) ??
      'local',
    syncVersion: (row.sync_version as number | null) ?? 0,
    snapshotHash: (row.snapshot_hash as string | null) ?? '',
    indexedAt: row.indexed_at as string,
    sourceLocator:
      nonEmptyString(row.source_locator) ?? nonEmptyString(row.file_path) ?? '',
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
    summaryMessageCount:
      (row.summary_message_count as number | null) ?? undefined,
    origin: (row.origin as string | null) ?? undefined,
    tier: row.tier as string | null as AuthoritativeSessionSnapshot['tier'],
    agentRole: (row.agent_role as string | null) ?? undefined,
  };
}

function applyFilters(
  conditions: string[],
  params: Record<string, unknown>,
  opts: Pick<
    ListSessionsOptions,
    | 'source'
    | 'sources'
    | 'project'
    | 'projects'
    | 'since'
    | 'until'
    | 'agents'
    | 'includeOrphans'
  >,
  noiseFilter: NoiseFilter,
  resolveAliases: (projects: string[]) => string[],
): void {
  const effectiveSources = opts.sources?.length
    ? opts.sources
    : opts.source
      ? [opts.source]
      : [];
  if (effectiveSources.length === 1) {
    conditions.push('source = @source');
    params.source = effectiveSources[0];
  } else if (effectiveSources.length > 1) {
    const placeholders = effectiveSources.map((s, i) => {
      params[`s${i}`] = s;
      return `@s${i}`;
    });
    conditions.push(`source IN (${placeholders.join(',')})`);
  }
  const rawProjects = opts.projects?.length
    ? opts.projects
    : opts.project
      ? [opts.project]
      : [];
  const effectiveProjects =
    rawProjects.length > 0 ? resolveAliases(rawProjects) : rawProjects;
  if (effectiveProjects.length === 1) {
    conditions.push('project = @project');
    params.project = effectiveProjects[0];
  } else if (effectiveProjects.length > 1) {
    const placeholders = effectiveProjects.map((p, i) => {
      params[`p${i}`] = p;
      return `@p${i}`;
    });
    conditions.push(`project IN (${placeholders.join(',')})`);
  }
  if ('since' in opts && opts.since) {
    conditions.push('start_time >= @since');
    params.since = opts.since;
  }
  if ('until' in opts && opts.until) {
    conditions.push('start_time <= @until');
    params.until = opts.until;
  }
  if (opts.agents === 'hide') {
    conditions.push(...buildTierFilter(noiseFilter));
  } else if (opts.agents === 'only') {
    conditions.push(
      "(agent_role IS NOT NULL OR file_path LIKE '%/subagents/%')",
    );
  }
  conditions.push(...buildOrphanFilter(opts.includeOrphans));
}

export function upsertSession(
  db: BetterSqlite3.Database,
  session: SessionInfo,
): void {
  db.prepare(`
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
      file_path = CASE WHEN sessions.file_path = '' AND excluded.file_path != '' THEN excluded.file_path ELSE sessions.file_path END,
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
  });
}

export function applyParentLink(
  db: BetterSqlite3.Database,
  session: SessionInfo,
): void {
  if (!session.parentSessionId) return;

  // Don't overwrite manual decisions
  const existing = db
    .prepare('SELECT link_source FROM sessions WHERE id = ?')
    .get(session.id) as { link_source: string | null } | undefined;
  if (existing?.link_source === 'manual') return;

  const validation = validateParentLink(
    db,
    session.id,
    session.parentSessionId,
  );
  if (validation === 'ok') {
    setParentSession(db, session.id, session.parentSessionId, 'path');
  }
  // If parent-not-found, silently skip — Pass 1 backfill will retry
}

export function getSessionByFilePath(
  db: BetterSqlite3.Database,
  filePath: string,
): SessionInfo | null {
  const row = db
    .prepare(`
    SELECT s.*, ls.local_readable_path
    FROM sessions s
    LEFT JOIN session_local_state ls ON ls.session_id = s.id
    WHERE s.file_path = ?
    LIMIT 1
  `)
    .get(filePath) as Record<string, unknown> | undefined;
  return row ? rowToSession(row) : null;
}

export function getSession(
  db: BetterSqlite3.Database,
  id: string,
): SessionInfo | null {
  const row = db
    .prepare(`
    SELECT s.*, ls.local_readable_path
    FROM sessions s
    LEFT JOIN session_local_state ls ON ls.session_id = s.id
    WHERE s.id = ?
  `)
    .get(id) as Record<string, unknown> | undefined;
  return row ? rowToSession(row) : null;
}

export function listSessions(
  db: BetterSqlite3.Database,
  opts: ListSessionsOptions,
  noiseFilter: NoiseFilter,
  resolveAliases: (projects: string[]) => string[],
): SessionInfo[] {
  const conditions: string[] = ['hidden_at IS NULL'];
  const params: Record<string, unknown> = {};

  applyFilters(conditions, params, opts, noiseFilter, resolveAliases);

  const where = `WHERE ${conditions.join(' AND ')}`;
  const limit = opts.limit ?? 20;
  const offset = opts.offset ?? 0;

  const rows = db
    .prepare(`
    SELECT base.*, ls.local_readable_path
    FROM (
      SELECT * FROM sessions ${where}
      ORDER BY start_time DESC
      LIMIT @limit OFFSET @offset
    ) base
    LEFT JOIN session_local_state ls ON ls.session_id = base.id
    ORDER BY base.start_time DESC
  `)
    .all({ ...params, limit, offset }) as Record<string, unknown>[];

  return rows.map((r) => rowToSession(r));
}

export function listSessionsSince(
  db: BetterSqlite3.Database,
  since: string,
  limit = 100,
): SessionInfo[] {
  const rows = db
    .prepare(`
    SELECT s.*, ls.local_readable_path
    FROM sessions s
    LEFT JOIN session_local_state ls ON ls.session_id = s.id
    WHERE s.indexed_at > @since AND s.hidden_at IS NULL
    ORDER BY s.indexed_at ASC
    LIMIT @limit
  `)
    .all({ since, limit }) as Record<string, unknown>[];
  return rows.map((r) => rowToSession(r));
}

export function listSessionsAfterCursor(
  db: BetterSqlite3.Database,
  cursor: SyncCursor | null,
  limit = 100,
): AuthoritativeSessionSnapshot[] {
  const rows = cursor
    ? (db
        .prepare(`
        SELECT *
        FROM sessions
        WHERE hidden_at IS NULL
          AND (
            indexed_at > @indexedAt
            OR (indexed_at = @indexedAt AND id > @sessionId)
          )
        ORDER BY indexed_at ASC, id ASC
        LIMIT @limit
      `)
        .all({
          indexedAt: cursor.indexedAt,
          sessionId: cursor.sessionId,
          limit,
        }) as Record<string, unknown>[])
    : (db
        .prepare(`
        SELECT *
        FROM sessions
        WHERE hidden_at IS NULL
        ORDER BY indexed_at ASC, id ASC
        LIMIT @limit
      `)
        .all({ limit }) as Record<string, unknown>[]);

  return rows.map((r) => rowToAuthoritativeSnapshot(r));
}

export function deleteSession(db: BetterSqlite3.Database, id: string): void {
  db.prepare('DELETE FROM sessions WHERE id = ?').run(id);
  db.prepare('DELETE FROM sessions_fts WHERE session_id = ?').run(id);
}

export function isIndexed(
  db: BetterSqlite3.Database,
  filePath: string,
  sizeBytes: number,
): boolean {
  const row = db
    .prepare(
      'SELECT id FROM sessions WHERE (file_path = ? OR source_locator = ?) AND size_bytes = ?',
    )
    .get(filePath, filePath, sizeBytes);
  return row !== undefined;
}

export function countSessions(
  db: BetterSqlite3.Database,
  opts: Pick<
    ListSessionsOptions,
    'source' | 'sources' | 'project' | 'projects' | 'agents'
  >,
  noiseFilter: NoiseFilter,
  resolveAliases: (projects: string[]) => string[],
): number {
  const conditions: string[] = ['hidden_at IS NULL'];
  const params: Record<string, unknown> = {};
  applyFilters(conditions, params, opts, noiseFilter, resolveAliases);
  return (
    db
      .prepare(
        `SELECT COUNT(*) as n FROM sessions WHERE ${conditions.join(' AND ')}`,
      )
      .get(params) as { n: number }
  ).n;
}

export function countTodayParentSessions(
  db: BetterSqlite3.Database,
  noiseFilter: NoiseFilter,
  now: Date = new Date(),
  timeZone: string = Intl.DateTimeFormat().resolvedOptions().timeZone,
): number {
  const range = getLocalTimeRange(now, timeZone);
  const conditions: string[] = [
    'hidden_at IS NULL',
    'parent_session_id IS NULL',
    'suggested_parent_id IS NULL',
    'datetime(start_time) >= datetime(@dayStart)',
    'datetime(start_time) < datetime(@dayEnd)',
  ];
  conditions.push(...buildTierFilter(noiseFilter));
  conditions.push(...buildOrphanFilter());
  return (
    db
      .prepare(
        `SELECT COUNT(*) as n FROM sessions WHERE ${conditions.join(' AND ')}`,
      )
      .get({
        dayStart: range.startUtcIso,
        dayEnd: range.endUtcIso,
      }) as { n: number }
  ).n;
}

export function listSources(db: BetterSqlite3.Database): string[] {
  const rows = db
    .prepare(
      'SELECT DISTINCT source FROM sessions WHERE hidden_at IS NULL ORDER BY source',
    )
    .all() as { source: string }[];
  return rows.map((r) => r.source);
}

export function getSourceStats(db: BetterSqlite3.Database): {
  source: string;
  sessionCount: number;
  latestIndexed: string;
  dailyCounts: number[];
}[] {
  const sourceRows = db
    .prepare(`
    SELECT source, COUNT(*) as count, MAX(indexed_at) as latest_indexed
    FROM sessions WHERE hidden_at IS NULL
    GROUP BY source ORDER BY count DESC
  `)
    .all() as { source: string; count: number; latest_indexed: string }[];

  if (sourceRows.length === 0) return [];

  const dailyRows = db
    .prepare(`
    SELECT source, date(start_time) as day, COUNT(*) as count
    FROM sessions
    WHERE hidden_at IS NULL AND start_time >= date('now', '-7 days')
    GROUP BY source, date(start_time)
  `)
    .all() as { source: string; day: string; count: number }[];

  const days: string[] = [];
  for (let i = 6; i >= 0; i--) {
    const d = new Date(Date.now() - i * 86400000);
    days.push(d.toISOString().slice(0, 10));
  }

  const dailyMap = new Map<string, Map<string, number>>();
  for (const row of dailyRows) {
    if (!dailyMap.has(row.source)) dailyMap.set(row.source, new Map());
    dailyMap.get(row.source)?.set(row.day, row.count);
  }

  return sourceRows.map((row) => ({
    source: row.source,
    sessionCount: row.count,
    latestIndexed: row.latest_indexed ?? '',
    dailyCounts: days.map((d) => dailyMap.get(row.source)?.get(d) ?? 0),
  }));
}

export function listProjects(db: BetterSqlite3.Database): string[] {
  const rows = db
    .prepare(
      'SELECT DISTINCT project FROM sessions WHERE hidden_at IS NULL AND project IS NOT NULL ORDER BY project',
    )
    .all() as { project: string }[];
  return rows.map((r) => r.project);
}

export function updateSessionSummary(
  db: BetterSqlite3.Database,
  id: string,
  summary: string,
  messageCount?: number,
): void {
  if (messageCount !== undefined) {
    db.prepare(
      'UPDATE sessions SET summary = ?, summary_message_count = ? WHERE id = ?',
    ).run(summary, messageCount, id);
  } else {
    db.prepare('UPDATE sessions SET summary = ? WHERE id = ?').run(summary, id);
  }
}

export function upsertAuthoritativeSnapshot(
  db: BetterSqlite3.Database,
  snapshot: AuthoritativeSessionSnapshot,
  getLocalState: (sessionId: string) => { localReadablePath?: string } | null,
): void {
  const localReadablePath = pickReadableSessionPath(
    getLocalState(snapshot.id)?.localReadablePath,
    isReadableSessionPath(snapshot.sourceLocator)
      ? snapshot.sourceLocator
      : null,
  );
  db.prepare(`
    INSERT INTO sessions (
      id, source, start_time, end_time, cwd, project, model,
      message_count, user_message_count, assistant_message_count, tool_message_count, system_message_count,
      summary, summary_message_count, file_path, size_bytes, indexed_at, origin,
      authoritative_node, source_locator, sync_version, snapshot_hash,
      tier, agent_role, quality_score
    ) VALUES (
      @id, @source, @startTime, @endTime, @cwd, @project, @model,
      @messageCount, @userMessageCount, @assistantMessageCount, @toolMessageCount, @systemMessageCount,
      @summary, @summaryMessageCount, @legacyFilePath, @sizeBytes, @indexedAt, @origin,
      @authoritativeNode, @sourceLocator, @syncVersion, @snapshotHash,
      @tier, @agentRole, @qualityScore
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
      file_path = CASE
        WHEN (sessions.file_path IS NULL OR sessions.file_path = '')
             AND excluded.source_locator NOT LIKE 'sync://%'
          THEN excluded.source_locator
        ELSE sessions.file_path
      END,
      sync_version = excluded.sync_version,
      snapshot_hash = excluded.snapshot_hash,
      tier = excluded.tier,
      agent_role = excluded.agent_role,
      quality_score = excluded.quality_score
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
    tier: snapshot.tier ?? 'normal',
    agentRole: snapshot.agentRole ?? null,
    qualityScore: computeQualityScore({
      userCount: snapshot.userMessageCount,
      assistantCount: snapshot.assistantMessageCount,
      toolCount: snapshot.toolMessageCount,
      systemCount: snapshot.systemMessageCount,
      startTime: snapshot.startTime,
      endTime: snapshot.endTime,
      project: snapshot.project,
    }),
  });
}

export function getAuthoritativeSnapshot(
  db: BetterSqlite3.Database,
  id: string,
): AuthoritativeSessionSnapshot | null {
  const row = db.prepare('SELECT * FROM sessions WHERE id = ?').get(id) as
    | Record<string, unknown>
    | undefined;
  return row ? rowToAuthoritativeSnapshot(row) : null;
}
