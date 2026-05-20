import {
  chmodSync,
  existsSync,
  mkdtempSync,
  rmSync,
  statSync,
  writeFileSync,
} from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { describe, expect, it } from 'vitest';
import { Database } from '../../src/core/db.js';

function mode(path: string): number {
  return statSync(path).mode & 0o777;
}

describe('database file permissions', () => {
  it('creates sqlite database files as user-only readable', () => {
    const dir = mkdtempSync(join(tmpdir(), 'engram-db-'));
    const dbPath = join(dir, 'index.sqlite');
    try {
      const db = new Database(dbPath);
      db.close();

      expect(mode(dbPath)).toBe(0o600);
      for (const suffix of ['-wal', '-shm']) {
        const auxPath = `${dbPath}${suffix}`;
        if (existsSync(auxPath)) {
          expect(mode(auxPath)).toBe(0o600);
        }
      }
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  it('repairs loose permissions on an existing sqlite database file', () => {
    const dir = mkdtempSync(join(tmpdir(), 'engram-db-'));
    const dbPath = join(dir, 'index.sqlite');
    try {
      writeFileSync(dbPath, '');
      chmodSync(dbPath, 0o644);

      const db = new Database(dbPath);
      db.close();

      expect(mode(dbPath)).toBe(0o600);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });
});
