import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { diagnose, queryHealth } from '../../src/cli/health.js';
import { Database } from '../../src/core/db.js';

describe('queryHealth', () => {
  let db: Database;
  beforeEach(() => {
    db = new Database(':memory:');
  });
  afterEach(() => {
    db.close();
  });

  it('returns table row counts', () => {
    const result = queryHealth(db.raw);
    expect(result.tables).toHaveProperty('logs');
    expect(result.tables).toHaveProperty('traces');
    expect(result.tables).toHaveProperty('metrics');
    expect(result.tables.logs).toBe(0);
  });

  it('returns db size info', () => {
    const result = queryHealth(db.raw);
    expect(result).toHaveProperty('dbSizeBytes');
    expect(typeof result.dbSizeBytes).toBe('number');
  });
});

describe('diagnose', () => {
  let db: Database;
  beforeEach(() => {
    db = new Database(':memory:');
    // Insert some errors
    const logStmt = db.raw.prepare(
      "INSERT INTO logs (ts, level, module, message, source) VALUES (?, ?, ?, ?, 'daemon')",
    );
    logStmt.run('2026-03-22T10:00:00.000', 'error', 'indexer', 'parse failed');
    logStmt.run('2026-03-22T10:01:00.000', 'error', 'indexer', 'parse failed');
    logStmt.run(
      '2026-03-22T11:00:00.000',
      'error',
      'viking',
      'connection timeout',
    );
  });
  afterEach(() => {
    db.close();
  });

  it('returns error summary', () => {
    const result = diagnose(db.raw, {});
    expect(result.errorCount).toBe(3);
    expect(result.errorsByModule).toHaveProperty('indexer');
    expect(result.errorsByModule.indexer).toBe(2);
  });

  it('filters by time range', () => {
    const result = diagnose(db.raw, { since: '2026-03-22T10:30:00.000' });
    expect(result.errorCount).toBe(1);
  });
});
