// src/core/ai-audit.ts
import { EventEmitter } from 'events'
import type Database from 'better-sqlite3'
import type { AiAuditConfig } from './config.js'
import { applyPatterns } from './sanitizer.js'
import { getRequestContext } from './request-context.js'

export interface AiAuditRecord {
  id?: number
  ts?: string
  traceId?: string
  caller: string
  operation: string
  requestSource?: string
  method?: string
  url?: string
  statusCode?: number
  model?: string
  provider?: string
  promptTokens?: number
  completionTokens?: number
  totalTokens?: number
  requestBody?: unknown
  responseBody?: unknown
  durationMs: number
  error?: string
  sessionId?: string
  meta?: Record<string, unknown>
}

export interface AiAuditStats {
  timeRange: { from: string; to: string }
  totals: {
    requests: number
    errors: number
    promptTokens: number
    completionTokens: number
    avgDurationMs: number
  }
  byCaller: Record<string, { requests: number; errors: number; promptTokens: number; completionTokens: number }>
  byModel: Record<string, { requests: number; promptTokens: number; completionTokens: number }>
  hourly: { hour: string; requests: number; tokens: number }[]
}

function stringify(value: unknown): string | null {
  if (value == null) return null
  if (typeof value === 'string') return value
  try { return JSON.stringify(value) } catch { return null }
}

function truncate(str: string | null, max: number): string | null {
  if (!str || str.length <= max) return str
  return str.slice(0, max) + '...[truncated]'
}

export class AiAuditWriter extends EventEmitter {
  private stmt: Database.Statement | null = null

  constructor(private db: Database.Database, private config: AiAuditConfig) {
    super()
    try {
      this.stmt = db.prepare(`
        INSERT INTO ai_audit_log (trace_id, caller, operation, request_source,
          method, url, status_code, duration_ms, model, provider,
          prompt_tokens, completion_tokens, total_tokens,
          request_body, response_body, error, session_id, meta)
        VALUES (@traceId, @caller, @operation, @requestSource,
          @method, @url, @statusCode, @durationMs, @model, @provider,
          @promptTokens, @completionTokens, @totalTokens,
          @requestBody, @responseBody, @error, @sessionId, @meta)
      `)
    } catch { /* table may not exist yet in tests */ }
  }

  record(entry: AiAuditRecord): number {
    if (!this.config.enabled) return -1
    try {
      const ctx = getRequestContext()
      const traceId = entry.traceId || ctx?.requestId || null
      const requestSource = entry.requestSource || ctx?.source || null

      let requestBody: string | null = null
      let responseBody: string | null = null
      if (this.config.logBodies) {
        requestBody = truncate(applyPatterns(stringify(entry.requestBody) || ''), this.config.maxBodySize)
        responseBody = truncate(applyPatterns(stringify(entry.responseBody) || ''), this.config.maxBodySize)
      }

      const url = entry.url ? applyPatterns(entry.url) : null

      const result = this.stmt!.run({
        traceId,
        caller: entry.caller,
        operation: entry.operation,
        requestSource,
        method: entry.method || null,
        url,
        statusCode: entry.statusCode ?? null,
        durationMs: entry.durationMs,
        model: entry.model || null,
        provider: entry.provider || null,
        promptTokens: entry.promptTokens ?? null,
        completionTokens: entry.completionTokens ?? null,
        totalTokens: entry.totalTokens ?? null,
        requestBody,
        responseBody,
        error: entry.error || null,
        sessionId: entry.sessionId || null,
        meta: entry.meta ? JSON.stringify(entry.meta) : null,
      })

      const id = Number(result.lastInsertRowid)
      this.emit('entry', { id, ...entry, traceId, requestSource })
      return id
    } catch {
      return -1
    }
  }

  cleanup(retentionDays: number): number {
    try {
      const result = this.db.prepare(
        `DELETE FROM ai_audit_log WHERE ts < datetime('now', '-' || ? || ' days')`
      ).run(retentionDays)
      return result.changes
    } catch { return 0 }
  }
}

export class AiAuditQuery {
  constructor(private db: Database.Database) {}

  list(filters: {
    caller?: string; model?: string; sessionId?: string
    from?: string; to?: string; hasError?: boolean
    limit?: number; offset?: number
  } = {}): { records: AiAuditRecord[]; total: number } {
    const conditions: string[] = []
    const params: Record<string, unknown> = {}

    if (filters.caller) { conditions.push('caller = @caller'); params.caller = filters.caller }
    if (filters.model) { conditions.push('model = @model'); params.model = filters.model }
    if (filters.sessionId) { conditions.push('session_id = @sessionId'); params.sessionId = filters.sessionId }
    if (filters.from) { conditions.push('ts > @from'); params.from = filters.from }
    if (filters.to) { conditions.push('ts <= @to'); params.to = filters.to }
    if (filters.hasError === true) conditions.push('error IS NOT NULL')
    if (filters.hasError === false) conditions.push('error IS NULL')

    const where = conditions.length > 0 ? `WHERE ${conditions.join(' AND ')}` : ''
    const limit = filters.limit ?? 50
    const offset = filters.offset ?? 0

    const rows = this.db.prepare(
      `SELECT * FROM ai_audit_log ${where} ORDER BY ts DESC LIMIT @limit OFFSET @offset`
    ).all({ ...params, limit, offset }) as any[]

    const countRow = this.db.prepare(
      `SELECT COUNT(*) as c FROM ai_audit_log ${where}`
    ).get(params) as any

    return {
      records: rows.map(r => this.rowToRecord(r)),
      total: countRow?.c ?? 0,
    }
  }

  get(id: number): AiAuditRecord | null {
    const row = this.db.prepare('SELECT * FROM ai_audit_log WHERE id = ?').get(id) as any
    return row ? this.rowToRecord(row) : null
  }

  stats(timeRange?: { from?: string; to?: string }): AiAuditStats {
    const from = timeRange?.from || new Date(Date.now() - 86400000).toISOString()
    const to = timeRange?.to || new Date().toISOString()
    const where = 'WHERE ts > @from AND ts <= @to'
    const params = { from, to }

    const totalsRow = this.db.prepare(`
      SELECT COUNT(*) as requests,
        SUM(CASE WHEN error IS NOT NULL THEN 1 ELSE 0 END) as errors,
        COALESCE(SUM(prompt_tokens), 0) as promptTokens,
        COALESCE(SUM(completion_tokens), 0) as completionTokens,
        COALESCE(AVG(duration_ms), 0) as avgDurationMs
      FROM ai_audit_log ${where}
    `).get(params) as any

    const callerRows = this.db.prepare(`
      SELECT caller,
        COUNT(*) as requests,
        SUM(CASE WHEN error IS NOT NULL THEN 1 ELSE 0 END) as errors,
        COALESCE(SUM(prompt_tokens), 0) as promptTokens,
        COALESCE(SUM(completion_tokens), 0) as completionTokens
      FROM ai_audit_log ${where} GROUP BY caller
    `).all(params) as any[]

    const modelRows = this.db.prepare(`
      SELECT model,
        COUNT(*) as requests,
        COALESCE(SUM(prompt_tokens), 0) as promptTokens,
        COALESCE(SUM(completion_tokens), 0) as completionTokens
      FROM ai_audit_log ${where} AND model IS NOT NULL GROUP BY model
    `).all(params) as any[]

    const hourlyRows = this.db.prepare(`
      SELECT strftime('%Y-%m-%dT%H:00', ts) as hour,
        COUNT(*) as requests,
        COALESCE(SUM(COALESCE(prompt_tokens, 0) + COALESCE(completion_tokens, 0)), 0) as tokens
      FROM ai_audit_log ${where} GROUP BY hour ORDER BY hour
    `).all(params) as any[]

    const byCaller: Record<string, { requests: number; errors: number; promptTokens: number; completionTokens: number }> = {}
    for (const r of callerRows) byCaller[r.caller] = { requests: r.requests, errors: r.errors, promptTokens: r.promptTokens, completionTokens: r.completionTokens }

    const byModel: Record<string, { requests: number; promptTokens: number; completionTokens: number }> = {}
    for (const r of modelRows) if (r.model) byModel[r.model] = { requests: r.requests, promptTokens: r.promptTokens, completionTokens: r.completionTokens }

    return {
      timeRange: { from, to },
      totals: {
        requests: totalsRow.requests,
        errors: totalsRow.errors,
        promptTokens: totalsRow.promptTokens,
        completionTokens: totalsRow.completionTokens,
        avgDurationMs: Math.round(totalsRow.avgDurationMs),
      },
      byCaller,
      byModel,
      hourly: hourlyRows.map((r: any) => ({ hour: r.hour, requests: r.requests, tokens: r.tokens })),
    }
  }

  private rowToRecord(r: any): AiAuditRecord {
    return {
      id: r.id,
      ts: r.ts,
      traceId: r.trace_id,
      caller: r.caller,
      operation: r.operation,
      requestSource: r.request_source,
      method: r.method,
      url: r.url,
      statusCode: r.status_code,
      durationMs: r.duration_ms,
      model: r.model,
      provider: r.provider,
      promptTokens: r.prompt_tokens,
      completionTokens: r.completion_tokens,
      totalTokens: r.total_tokens,
      requestBody: r.request_body,
      responseBody: r.response_body,
      error: r.error,
      sessionId: r.session_id,
      meta: r.meta ? JSON.parse(r.meta) : null,
    }
  }
}
