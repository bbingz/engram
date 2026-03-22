// src/cli/traces.ts
// CLI diagnostic: query and display trace spans from the observability DB
import type BetterSqlite3 from 'better-sqlite3'
import { Database } from '../core/db.js'
import { resolve } from 'path'
import { homedir } from 'os'

export interface TraceFilters {
  slow?: number
  name?: string
  traceId?: string
  limit?: number
}

export interface TraceRow {
  id: number
  trace_id: string
  span_id: string
  parent_span_id: string | null
  name: string
  module: string
  start_ts: string
  end_ts: string | null
  duration_ms: number | null
  status: string
  attributes: string | null
  source: string
}

export function queryTraces(db: BetterSqlite3.Database, filters: TraceFilters): TraceRow[] {
  const conditions: string[] = []
  const params: unknown[] = []

  if (filters.slow != null) {
    conditions.push('duration_ms >= ?')
    params.push(filters.slow)
  }
  if (filters.name) {
    conditions.push('name LIKE ?')
    params.push(filters.name)
  }
  if (filters.traceId) {
    conditions.push('trace_id = ?')
    params.push(filters.traceId)
  }

  const where = conditions.length > 0 ? `WHERE ${conditions.join(' AND ')}` : ''
  const limit = filters.limit ?? 50
  const sql = `SELECT * FROM traces ${where} ORDER BY start_ts DESC LIMIT ?`
  params.push(limit)

  return db.prepare(sql).all(...params) as TraceRow[]
}

export function formatTraces(rows: TraceRow[], json = false): string {
  if (json) return JSON.stringify(rows, null, 2)

  if (rows.length === 0) return 'No traces found.'

  return rows.map(row => {
    const dur = row.duration_ms != null ? `${row.duration_ms}ms` : 'in-progress'
    const status = row.status === 'ok' ? 'OK' : row.status.toUpperCase()
    return `[${row.start_ts}] ${row.name} (${row.module}) ${dur} [${status}]  trace=${row.trace_id}`
  }).join('\n')
}

function parseArgs(args: string[]): TraceFilters & { json?: boolean } {
  const filters: TraceFilters & { json?: boolean } = {}
  for (let i = 0; i < args.length; i++) {
    const arg = args[i]
    const next = args[i + 1]
    if (arg === '--slow' && next) { filters.slow = parseInt(next, 10); i++ }
    else if (arg === '--name' && next) { filters.name = next; i++ }
    else if (arg === '--trace-id' && next) { filters.traceId = next; i++ }
    else if (arg === '--limit' && next) { filters.limit = parseInt(next, 10); i++ }
    else if (arg === '--json') { filters.json = true }
  }
  return filters
}

export function main(args: string[]): void {
  const filters = parseArgs(args)
  const dbPath = resolve(homedir(), '.engram', 'index.sqlite')
  const db = new Database(dbPath)
  try {
    const rows = queryTraces(db.raw, filters)
    console.log(formatTraces(rows, filters.json))
  } finally {
    db.close()
  }
}
