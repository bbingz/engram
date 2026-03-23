// tests/integration/request-tracing.test.ts
import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest'
import { Database } from '../../src/core/db.js'
import { LogWriter, createLogger } from '../../src/core/logger.js'
import { TraceWriter, Tracer, withSpan } from '../../src/core/tracer.js'
import { runWithContext, getRequestId } from '../../src/core/request-context.js'

describe('end-to-end request tracing', () => {
  let db: Database
  let logWriter: LogWriter
  let tracer: Tracer
  let stderrOutput: string[]

  beforeEach(() => {
    db = new Database(':memory:')
    logWriter = new LogWriter(db.raw)
    const traceWriter = new TraceWriter(db.raw)
    tracer = new Tracer(traceWriter)
    stderrOutput = []
    vi.spyOn(process.stderr, 'write').mockImplementation((chunk: any) => {
      stderrOutput.push(chunk.toString())
      return true
    })
  })
  afterEach(() => { db.close(); vi.restoreAllMocks() })

  it('correlates logs and traces within an MCP tool call', async () => {
    const log = createLogger('test', { writer: logWriter, level: 'info', stderrJson: true })

    await runWithContext({ requestId: 'mcp-req-1', source: 'mcp' }, async () => {
      log.info('tool invoked', { tool: 'search' })
      await withSpan(tracer, 'tool.search', 'mcp', async (span) => {
        span.setAttribute('query', 'test')
        log.info('search started')
      })
    })

    // Verify logs have matching trace_id
    const logs = db.raw.prepare('SELECT trace_id FROM logs').all() as any[]
    expect(logs).toHaveLength(2)
    expect(logs[0].trace_id).toBe('mcp-req-1')
    expect(logs[1].trace_id).toBe('mcp-req-1')

    // Verify trace has matching trace_id
    const traces = db.raw.prepare('SELECT trace_id FROM traces').all() as any[]
    expect(traces).toHaveLength(1)
    expect(traces[0].trace_id).toBe('mcp-req-1')

    // Verify stderr output
    expect(stderrOutput).toHaveLength(2)
    const parsed = JSON.parse(stderrOutput[0])
    expect(parsed.request_id).toBe('mcp-req-1')
    expect(parsed.request_source).toBe('mcp')
  })

  it('PII is sanitized in both SQLite and stderr', async () => {
    const log = createLogger('test', { writer: logWriter, level: 'info', stderrJson: true })

    runWithContext({ requestId: 'pii-test', source: 'http' }, () => {
      log.info('user email: user@secret.com, key: sk-abcdefghijklmnopqrstuvwx')
    })

    // SQLite sanitized
    const row = db.raw.prepare('SELECT message FROM logs').get() as any
    expect(row.message).toContain('***@***.***')
    expect(row.message).toContain('sk-***')
    expect(row.message).not.toContain('user@secret.com')

    // stderr sanitized
    const parsed = JSON.parse(stderrOutput[0])
    expect(parsed.message).toContain('***@***.***')
    expect(parsed.message).toContain('sk-***')
  })

  it('separate ALS contexts get different request_ids', async () => {
    const log = createLogger('test', { writer: logWriter, level: 'info' })

    await runWithContext({ requestId: 'req-A', source: 'indexer' }, async () => {
      log.info('file 1')
    })
    await runWithContext({ requestId: 'req-B', source: 'indexer' }, async () => {
      log.info('file 2')
    })

    const logs = db.raw.prepare('SELECT trace_id FROM logs ORDER BY id').all() as any[]
    expect(logs[0].trace_id).toBe('req-A')
    expect(logs[1].trace_id).toBe('req-B')
  })
})
