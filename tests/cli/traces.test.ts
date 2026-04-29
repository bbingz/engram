import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { queryTraces } from '../../src/cli/traces.js';
import { Database } from '../../src/core/db.js';

describe('queryTraces', () => {
  let db: Database;
  beforeEach(() => {
    db = new Database(':memory:');
    const stmt = db.raw.prepare(
      "INSERT INTO traces (trace_id, span_id, name, module, start_ts, end_ts, duration_ms, status, source) VALUES (?, ?, ?, ?, ?, ?, ?, ?, 'daemon')",
    );
    stmt.run(
      't1',
      's1',
      'indexAll',
      'indexer',
      '2026-03-22T10:00:00.000',
      '2026-03-22T10:00:02.500',
      2500,
      'ok',
    );
    stmt.run(
      't2',
      's2',
      'embeddingIndex',
      'semantic_index',
      '2026-03-22T11:00:00.000',
      '2026-03-22T11:00:05.000',
      5000,
      'error',
    );
    stmt.run(
      't3',
      's3',
      'ftsSearch',
      'search',
      '2026-03-22T12:00:00.000',
      '2026-03-22T12:00:00.100',
      100,
      'ok',
    );
  });
  afterEach(() => {
    db.close();
  });

  it('returns all traces by default', () => {
    const result = queryTraces(db.raw, {});
    expect(result).toHaveLength(3);
  });

  it('filters by slow threshold', () => {
    const result = queryTraces(db.raw, { slow: 3000 });
    expect(result).toHaveLength(1);
    expect(result[0].name).toBe('embeddingIndex');
  });

  it('filters by name pattern', () => {
    const result = queryTraces(db.raw, { name: 'embedding%' });
    expect(result).toHaveLength(1);
  });

  it('filters by traceId', () => {
    const result = queryTraces(db.raw, { traceId: 't1' });
    expect(result).toHaveLength(1);
    expect(result[0].name).toBe('indexAll');
  });
});
