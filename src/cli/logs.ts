// src/cli/logs.ts
// CLI diagnostic: query and display structured logs from the observability DB
import type BetterSqlite3 from 'better-sqlite3'
import { Database } from '../core/db.js'
import { resolve } from 'path'
import { homedir } from 'os'
import { parseDuration } from './utils.js'

export interface LogFilters {
  level?: string
  module?: string
  traceId?: string
  since?: string
  limit?: number
}

export interface LogRow {
  id: number
  ts: string
  level: string
  module: string
  trace_id: string | null
  span_id: string | null
  message: string
  data: string | null
  error_name: string | null
  error_message: string | null
  error_stack: string | null
  source: string
}

export function queryLogs(db: BetterSqlite3.Database, filters: LogFilters): LogRow[] {
  const conditions: string[] = []
  const params: unknown[] = []

  if (filters.level) {
    conditions.push('level = ?')
    params.push(filters.level)
  }
  if (filters.module) {
    conditions.push('module = ?')
    params.push(filters.module)
  }
  if (filters.traceId) {
    conditions.push('trace_id = ?')
    params.push(filters.traceId)
  }
  if (filters.since) {
    conditions.push('ts >= ?')
    params.push(filters.since)
  }

  const where = conditions.length > 0 ? `WHERE ${conditions.join(' AND ')}` : ''
  const limit = filters.limit ?? 100
  const sql = `SELECT * FROM logs ${where} ORDER BY ts DESC LIMIT ?`
  params.push(limit)

  return db.prepare(sql).all(...params) as LogRow[]
}

export function formatLogs(rows: LogRow[], json = false): string {
  if (json) return JSON.stringify(rows, null, 2)

  if (rows.length === 0) return 'No logs found.'

  return rows.map(row => {
    const levelTag = row.level.toUpperCase().padEnd(5)
    const parts = [`[${row.ts}] ${levelTag} [${row.module}] ${row.message}`]
    if (row.error_name) parts.push(`  Error: ${row.error_name}: ${row.error_message ?? ''}`)
    if (row.trace_id) parts.push(`  trace=${row.trace_id}`)
    return parts.join('\n')
  }).join('\n')
}

function parseArgs(args: string[]): LogFilters & { json?: boolean } {
  const filters: LogFilters & { json?: boolean } = {}
  for (let i = 0; i < args.length; i++) {
    const arg = args[i]
    const next = args[i + 1]
    if (arg === '--level' && next) { filters.level = next; i++ }
    else if (arg === '--module' && next) { filters.module = next; i++ }
    else if (arg === '--trace-id' && next) { filters.traceId = next; i++ }
    else if (arg === '--since' && next) { filters.since = next; i++ }
    else if (arg === '--last' && next) { filters.since = parseDuration(next); i++ }
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
    const rows = queryLogs(db.raw, filters)
    console.log(formatLogs(rows, filters.json))
  } finally {
    db.close()
  }
}
