// src/core/tracer.ts
import { randomUUID } from 'crypto'
import type BetterSqlite3 from 'better-sqlite3'

export interface SpanData {
  traceId: string
  spanId: string
  parentSpanId?: string
  name: string
  module: string
  startTs: string
  endTs?: string
  durationMs?: number
  status: 'ok' | 'error'
  attributes?: Record<string, unknown>
  source: 'daemon' | 'app'
}

export class TraceWriter {
  private insertStmt: BetterSqlite3.Statement

  constructor(private db: BetterSqlite3.Database) {
    this.insertStmt = db.prepare(`
      INSERT OR IGNORE INTO traces (trace_id, span_id, parent_span_id, name, module, start_ts, end_ts, duration_ms, status, attributes, source)
      VALUES (@traceId, @spanId, @parentSpanId, @name, @module, @startTs, @endTs, @durationMs, @status, @attributes, @source)
    `)
  }

  write(span: SpanData): void {
    this.insertStmt.run({
      traceId: span.traceId,
      spanId: span.spanId,
      parentSpanId: span.parentSpanId ?? null,
      name: span.name,
      module: span.module,
      startTs: span.startTs,
      endTs: span.endTs ?? null,
      durationMs: span.durationMs ?? null,
      status: span.status,
      attributes: span.attributes ? JSON.stringify(span.attributes) : null,
      source: span.source,
    })
  }
}

export interface Span {
  traceId: string
  spanId: string
  name: string
  end(): void
  setError(err: unknown): void
  setAttribute(key: string, value: unknown): void
}

export class Tracer {
  constructor(private writer: TraceWriter) {}

  startSpan(name: string, module: string, opts?: {
    parentSpan?: Span
    traceId?: string
    attributes?: Record<string, unknown>
  }): Span {
    const traceId = opts?.traceId ?? opts?.parentSpan?.traceId ?? randomUUID()
    const spanId = randomUUID()
    const parentSpanId = opts?.parentSpan?.spanId
    const startTs = new Date().toISOString()
    const startTime = Date.now()
    const attributes: Record<string, unknown> = { ...opts?.attributes }
    let ended = false

    const span: Span = {
      traceId,
      spanId,
      name,
      end: () => {
        if (ended) return
        ended = true
        this.writer.write({
          traceId, spanId, parentSpanId, name, module, startTs,
          endTs: new Date().toISOString(),
          durationMs: Date.now() - startTime,
          status: 'ok',
          attributes: Object.keys(attributes).length > 0 ? attributes : undefined,
          source: 'daemon',
        })
      },
      setError: (err: unknown) => {
        if (ended) return
        ended = true
        attributes.error = err instanceof Error ? err.message : String(err)
        this.writer.write({
          traceId, spanId, parentSpanId, name, module, startTs,
          endTs: new Date().toISOString(),
          durationMs: Date.now() - startTime,
          status: 'error',
          attributes,
          source: 'daemon',
        })
      },
      setAttribute: (key, value) => { attributes[key] = value },
    }
    return span
  }
}
