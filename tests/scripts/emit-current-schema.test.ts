import { execFileSync } from 'node:child_process';
import { mkdtempSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { afterEach, describe, expect, it } from 'vitest';

const repoRoot = resolve(import.meta.dirname, '../..');

describe('emit-current-schema', () => {
  let tmp = '';

  afterEach(() => {
    if (tmp) rmSync(tmp, { recursive: true, force: true });
  });

  it('emits deterministic base schema without lazy vector tables', () => {
    tmp = mkdtempSync(join(tmpdir(), 'engram-schema-test-'));
    const out = join(tmp, 'schema.json');

    execFileSync(
      './node_modules/.bin/tsx',
      ['scripts/db/emit-current-schema.ts', '--out', out],
      { cwd: repoRoot, stdio: 'pipe' },
    );

    const first = readFileSync(out, 'utf8');
    execFileSync(
      './node_modules/.bin/tsx',
      ['scripts/db/emit-current-schema.ts', '--out', out],
      { cwd: repoRoot, stdio: 'pipe' },
    );
    const second = readFileSync(out, 'utf8');
    const schema = JSON.parse(first);

    expect(second).toBe(first);
    expect(schema.schemaVersion).toBe(1);
    expect(schema.ftsVersion).toBe('3');
    expect(schema.tables.sessions.columns.id.type).toBe('TEXT');
    expect(schema.tables.metadata.columns.key.primaryKey).toBe(true);
    expect(schema.tables.sessions_fts.virtual).toBe(true);
    expect(schema.tables.vec_sessions).toBeUndefined();
  }, 20_000);
});
