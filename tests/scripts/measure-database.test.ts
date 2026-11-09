import { execFileSync, spawnSync } from 'node:child_process';
import { mkdtempSync, readdirSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';

const script = resolve('scripts/db/measure-database.py');
let root: string;
let database: string;

function seed(sql: string) {
  execFileSync(
    'python3',
    [
      '-c',
      `
import sqlite3, sys
with sqlite3.connect(sys.argv[1]) as db:
    db.executescript(sys.stdin.read())
`,
      database,
    ],
    { input: sql },
  );
}

function report() {
  return JSON.parse(
    execFileSync('python3', [script, '--database', database], {
      encoding: 'utf8',
    }),
  );
}

beforeEach(() => {
  root = mkdtempSync(join(tmpdir(), 'engram-measure-'));
  database = join(root, 'fixture ?# 数据.sqlite');
});
afterEach(() => rmSync(root, { recursive: true, force: true }));

describe('read-only database measurements', () => {
  it('reports exact distributions, FTS shares and storage without changing the database', () => {
    seed(`
      CREATE TABLE sessions(id TEXT PRIMARY KEY, tier TEXT, quality_score INTEGER);
      CREATE TABLE metadata(key TEXT PRIMARY KEY, value TEXT);
      INSERT INTO metadata VALUES('quality_score_formula_version', '1');
      INSERT INTO sessions VALUES
        ('a', 'normal', 0), ('b', 'normal', 35), ('c', 'normal', 36),
        ('d', 'premium', 60), ('e', NULL, 100), ('missing', 'lite', NULL),
        ('bad', 'normal', 'not-a-score'), ('skip', 'skip', 99);
      CREATE VIRTUAL TABLE sessions_fts USING fts5(session_id UNINDEXED, content);
      CREATE INDEX custom_identity_index ON sessions_fts_content(c0);
      INSERT INTO sessions_fts VALUES ('a', 'private transcript marker'), ('a', 'second'),
        ('d', 'third'), ('orphan', 'orphan body');
    `);
    const before = readFileSync(database);
    const files = readdirSync(root);
    const result = report();
    expect(result.sessions.total).toBe(8);
    expect(result.quality_score).toMatchObject({
      formula_version: '1',
      scored: 5,
      missing: 1,
      invalid: 1,
      min: 0,
      max: 100,
      mean: 46.2,
      percentiles: { p10: 0, p33: 35, p50: 36, p67: 60, p90: 100 },
    });
    expect(result.fts).toEqual({
      status: 'available',
      rows: 4,
      orphan_rows: 1,
    });
    expect(
      result.sessions.tiers.find(
        (item: { tier: string }) => item.tier === 'normal',
      ),
    ).toMatchObject({ sessions: 4, fts_rows: 2, fts_row_share: 0.5 });
    expect(result.storage.status).toBe('available');
    expect(result.storage.fts_bytes).toBeGreaterThan(0);
    const customIndex = result.storage.objects.find(
      (item: { name: string }) => item.name === 'custom_identity_index',
    );
    expect(customIndex.table).toBe('sessions_fts_content');
    expect(result.storage.fts_bytes).toBe(
      result.storage.objects
        .filter((item: { table: string }) =>
          item.table.startsWith('sessions_fts'),
        )
        .reduce((sum: number, item: { bytes: number }) => sum + item.bytes, 0),
    );
    expect(result.database.logical_bytes).toBe(
      result.database.page_count * result.database.page_size,
    );
    expect(JSON.stringify(result)).not.toContain('private transcript marker');
    expect(readFileSync(database)).toEqual(before);
    expect(readdirSync(root)).toEqual(files);
  });

  it('reports empty scores and a missing FTS table explicitly', () => {
    seed(
      'CREATE TABLE sessions(id TEXT PRIMARY KEY, tier TEXT, quality_score INTEGER);',
    );
    const result = report();
    expect(result.sessions.total).toBe(0);
    expect(result.quality_score).toMatchObject({
      scored: 0,
      min: null,
      max: null,
      mean: null,
    });
    expect(Object.values(result.quality_score.percentiles)).toEqual([
      null,
      null,
      null,
      null,
      null,
    ]);
    expect(result.fts.status).toBe('unavailable');
  });

  it('reads committed WAL content while a writer keeps the WAL open', () => {
    const result = JSON.parse(
      execFileSync(
        'python3',
        [
          '-c',
          `
import sqlite3, subprocess, sys
db = sqlite3.connect(sys.argv[1])
db.execute('PRAGMA journal_mode=WAL')
db.execute('PRAGMA wal_autocheckpoint=0')
db.execute('CREATE TABLE sessions(id TEXT PRIMARY KEY, tier TEXT, quality_score INTEGER)')
db.execute("INSERT INTO sessions VALUES('wal-only', 'normal', 77)")
db.commit()
print(subprocess.check_output([sys.executable, sys.argv[2], '--database', sys.argv[1]], text=True))
db.close()
`,
          database,
          script,
        ],
        { encoding: 'utf8' },
      ),
    );
    expect(result.sessions.total).toBe(1);
    expect(result.quality_score.min).toBe(77);
  });

  it('fails without creating missing databases or printing partial JSON', () => {
    const missing = spawnSync('python3', [script, '--database', database], {
      encoding: 'utf8',
    });
    expect(missing.status).not.toBe(0);
    expect(missing.stdout).toBe('');
    expect(readdirSync(root)).toEqual([]);
    seed('CREATE TABLE unrelated(id INTEGER);');
    const invalid = spawnSync('python3', [script, '--database', database], {
      encoding: 'utf8',
    });
    expect(invalid.status).not.toBe(0);
    expect(invalid.stdout).toBe('');
    expect(invalid.stderr).toContain('required sessions table is missing');
  });

  it('requires an explicit database and positive bounded timeout', () => {
    expect(
      spawnSync('python3', [script], { encoding: 'utf8' }).status,
    ).not.toBe(0);
    for (const timeout of ['0', '-1', 'nan', 'inf']) {
      expect(
        spawnSync('python3', [
          script,
          '--database',
          database,
          '--timeout',
          timeout,
        ]).status,
      ).not.toBe(0);
    }
  });

  it('returns failure without partial JSON when a database is locked', () => {
    seed(
      'CREATE TABLE sessions(id TEXT PRIMARY KEY, tier TEXT, quality_score INTEGER);',
    );
    const result = JSON.parse(
      execFileSync(
        'python3',
        [
          '-c',
          `
import json, sqlite3, subprocess, sys
db = sqlite3.connect(sys.argv[1])
db.execute('BEGIN EXCLUSIVE')
r = subprocess.run([sys.executable, sys.argv[2], '--database', sys.argv[1], '--timeout', '0.05'], capture_output=True, text=True)
print(json.dumps({'code': r.returncode, 'stdout': r.stdout, 'stderr': r.stderr}))
db.rollback()
db.close()
`,
          database,
          script,
        ],
        { encoding: 'utf8' },
      ),
    );
    expect(result.code).not.toBe(0);
    expect(result.stdout).toBe('');
    expect(result.stderr).toContain('database is locked');
  });
});
