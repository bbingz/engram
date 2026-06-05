# FTS Table-Swap Rebuild Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [x]`) syntax for tracking.

**Goal:** Add TypeScript `sessions_fts` online table-swap rebuild support that keeps active search available, builds a shadow FTS table safely, and swaps it in after recoverable FTS work is clear.

**Status (2026-06-06):** Completed and merged via PR #48,
`d199808c feat(db): add fts table-swap rebuild (#48)`. The implementation
added `src/core/db/fts-rebuild-policy.ts`, migration/repository/index-job
wiring, targeted Vitest coverage, and durable records in `CHANGELOG.md` /
`.memory`. The checklist below is marked complete to reflect current `main`;
the plan remains as historical implementation evidence.

**Architecture:** Add `src/core/db/fts-rebuild-policy.ts` as the fixed-name policy module for FTS version state, shadow table creation/copy, dual-write helpers, dual-delete helpers, and finalization. Wire migration, FTS write/delete paths, and `IndexJobRunner` through the policy while preserving existing search reads from active `sessions_fts`.

**Tech Stack:** TypeScript, better-sqlite3, SQLite FTS5, Vitest, Biome.

---

## Files

- Create: `src/core/db/fts-rebuild-policy.ts`
- Modify: `src/core/db/migration.ts`
- Modify: `src/core/db/fts-repo.ts`
- Modify: `src/core/db/database.ts`
- Modify: `src/core/db/session-repo.ts`
- Modify: `src/core/db/maintenance.ts`
- Modify: `src/core/index-job-runner.ts`
- Modify: `tests/core/db-migration.test.ts`
- Modify: `tests/core/db.test.ts`
- Modify: `tests/core/maintenance.test.ts`
- Modify: `tests/core/index-job-runner.test.ts`
- Modify: `CHANGELOG.md`
- Modify: `.memory`

## Task 1: Migration Starts An Idempotent Pending Rebuild

**Files:**
- Create: `src/core/db/fts-rebuild-policy.ts`
- Modify: `src/core/db/migration.ts`
- Test: `tests/core/db-migration.test.ts`

- [x] **Step 1: Write failing migration tests**

Add tests to `tests/core/db-migration.test.ts`:

```ts
it('starts an idempotent FTS table-swap rebuild while keeping active search live', () => {
  const dbPath = makeTmpDb();
  const rawDb = new BetterSqlite3(dbPath);
  rawDb.exec(`
    CREATE TABLE sessions (
      id TEXT PRIMARY KEY,
      source TEXT NOT NULL,
      start_time TEXT NOT NULL,
      cwd TEXT NOT NULL DEFAULT '',
      file_path TEXT NOT NULL,
      size_bytes INTEGER NOT NULL DEFAULT 123,
      indexed_at TEXT NOT NULL DEFAULT (datetime('now'))
    );
    CREATE TABLE metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL);
    CREATE TABLE session_index_jobs (
      id TEXT PRIMARY KEY,
      session_id TEXT NOT NULL,
      job_kind TEXT NOT NULL,
      target_sync_version INTEGER NOT NULL,
      status TEXT NOT NULL,
      retry_count INTEGER NOT NULL DEFAULT 0,
      last_error TEXT,
      created_at TEXT NOT NULL DEFAULT (datetime('now')),
      updated_at TEXT NOT NULL DEFAULT (datetime('now'))
    );
    CREATE TABLE session_embeddings (
      session_id TEXT PRIMARY KEY,
      embedding BLOB
    );
    CREATE TABLE vec_sessions (
      rowid INTEGER PRIMARY KEY,
      embedding BLOB
    );
    CREATE VIRTUAL TABLE sessions_fts USING fts5(
      session_id UNINDEXED,
      content,
      tokenize='trigram case_sensitive 0'
    );
    INSERT INTO metadata(key, value) VALUES ('fts_version', '2');
    INSERT INTO sessions (id, source, start_time, cwd, file_path, size_bytes)
    VALUES ('legacy-fts', 'codex', '2026-01-01T00:00:00Z', '/repo', '/tmp/session.jsonl', 123);
    INSERT INTO sessions_fts(session_id, content)
    VALUES ('legacy-fts', 'existing searchable text');
    INSERT INTO session_index_jobs(id, session_id, job_kind, target_sync_version, status)
    VALUES ('legacy-fts:1:fts', 'legacy-fts', 'fts', 1, 'completed');
    INSERT INTO session_embeddings(session_id, embedding)
    VALUES ('legacy-fts', x'0102');
    INSERT INTO vec_sessions(rowid, embedding)
    VALUES (1, x'0304');
  `);
  rawDb.close();

  const db = new Database(dbPath);
  expect(db.getFtsContent('legacy-fts')).toEqual(['existing searchable text']);
  expect(
    db.raw
      .prepare('SELECT content FROM sessions_fts_rebuild WHERE session_id = ?')
      .pluck()
      .all('legacy-fts'),
  ).toEqual(['existing searchable text']);
  expect(db.getMetadata('fts_rebuild_version')).toBe('3');
  expect(db.getMetadata('fts_version')).toBe('2');
  expect(
    db.raw.prepare('SELECT size_bytes FROM sessions WHERE id = ?').get('legacy-fts'),
  ).toEqual({ size_bytes: 0 });
  expect(
    db.raw.prepare('SELECT COUNT(*) AS count FROM session_embeddings').get(),
  ).toEqual({ count: 0 });
  expect(
    db.raw.prepare('SELECT COUNT(*) AS count FROM vec_sessions').get(),
  ).toEqual({ count: 0 });
  expect(
    db.raw
      .prepare('SELECT status, retry_count, last_error FROM session_index_jobs WHERE id = ?')
      .get('legacy-fts:1:fts'),
  ).toEqual({ status: 'pending', retry_count: 0, last_error: null });
  db.close();

  const reopened = new Database(dbPath);
  expect(
    reopened.raw
      .prepare('SELECT COUNT(*) AS count FROM sessions_fts_rebuild WHERE session_id = ?')
      .get('legacy-fts'),
  ).toEqual({ count: 1 });
  reopened.close();
});

it('marks FTS version current for an empty database without pending rebuild', () => {
  const dbPath = makeTmpDb();
  const rawDb = new BetterSqlite3(dbPath);
  rawDb.exec(`
    CREATE TABLE sessions (
      id TEXT PRIMARY KEY,
      source TEXT NOT NULL,
      start_time TEXT NOT NULL,
      cwd TEXT NOT NULL DEFAULT '',
      file_path TEXT NOT NULL
    );
    CREATE TABLE metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL);
    INSERT INTO metadata(key, value) VALUES ('fts_version', '2');
  `);
  rawDb.close();

  const db = new Database(dbPath);
  expect(db.getMetadata('fts_version')).toBe('3');
  expect(db.getMetadata('fts_rebuild_version')).toBeNull();
  expect(
    db.raw
      .prepare("SELECT name FROM sqlite_master WHERE type='table' AND name='sessions_fts_rebuild'")
      .get(),
  ).toBeUndefined();
  db.close();
});
```

- [x] **Step 2: Run tests and verify they fail**

Run:

```bash
npx vitest run tests/core/db-migration.test.ts -t "FTS table-swap|empty database"
```

Expected: FAIL because `sessions_fts_rebuild` and `fts_rebuild_version` do not exist yet.

- [x] **Step 3: Add the rebuild policy module and wire migration**

Create `src/core/db/fts-rebuild-policy.ts` with fixed-name helpers:

```ts
import type BetterSqlite3 from 'better-sqlite3';

export const FTS_VERSION = '3';
const REBUILD_VERSION_KEY = 'fts_rebuild_version';
const ACTIVE_TABLE = 'sessions_fts';
const REBUILD_TABLE = 'sessions_fts_rebuild';
const OLD_TABLE = 'sessions_fts_old';

type MetadataAccess = {
  getMetadata: (key: string) => string | null;
  setMetadata: (key: string, value: string) => void;
};

export function applyFtsRebuildPolicy(
  db: BetterSqlite3.Database,
  metadata: MetadataAccess,
): void {
  const current = metadata.getMetadata('fts_version');
  if (current === FTS_VERSION) return;

  const tx = db.transaction(() => {
    if (sessionCount(db) === 0) {
      db.exec(`DROP TABLE IF EXISTS ${REBUILD_TABLE}`);
      metadata.setMetadata('fts_version', FTS_VERSION);
      deleteMetadata(db, REBUILD_VERSION_KEY);
      return;
    }

    const pending = metadata.getMetadata(REBUILD_VERSION_KEY);
    const rebuildMissing = !tableExists(db, REBUILD_TABLE);
    const needsFreshRebuild = pending !== FTS_VERSION || rebuildMissing;
    if (needsFreshRebuild) {
      db.exec(`DROP TABLE IF EXISTS ${REBUILD_TABLE}`);
      createSessionsFtsTable(db, REBUILD_TABLE);
      if (tableExists(db, ACTIVE_TABLE)) {
        db.exec(`
          INSERT INTO ${REBUILD_TABLE}(session_id, content)
          SELECT session_id, content FROM ${ACTIVE_TABLE}
        `);
      }
    }

    db.exec('UPDATE sessions SET size_bytes = 0');
    deleteIfExists(db, 'session_embeddings');
    deleteIfExists(db, 'vec_sessions');
    metadata.setMetadata(REBUILD_VERSION_KEY, FTS_VERSION);
    reopenCompletedFtsJobs(db);
    finalizeFtsRebuildIfReady(db, metadata);
  });
  tx();
}

export function createSessionsFtsTable(
  db: BetterSqlite3.Database,
  table: typeof ACTIVE_TABLE | typeof REBUILD_TABLE,
  options: { ifNotExists?: boolean } = {},
): void {
  const existsClause = options.ifNotExists ? 'IF NOT EXISTS ' : '';
  db.exec(`
    CREATE VIRTUAL TABLE ${existsClause}${table} USING fts5(
      session_id UNINDEXED,
      content,
      tokenize='trigram case_sensitive 0'
    )
  `);
}

export function finalizeFtsRebuildIfReady(
  db: BetterSqlite3.Database,
  metadata: MetadataAccess,
): boolean {
  if (metadata.getMetadata(REBUILD_VERSION_KEY) !== FTS_VERSION) return false;
  if (!tableExists(db, REBUILD_TABLE)) return false;
  if (recoverableFtsJobCount(db) > 0) return false;

  const tx = db.transaction(() => {
    db.exec(`DROP TABLE IF EXISTS ${OLD_TABLE}`);
    if (tableExists(db, ACTIVE_TABLE)) {
      db.exec(`ALTER TABLE ${ACTIVE_TABLE} RENAME TO ${OLD_TABLE}`);
    }
    db.exec(`ALTER TABLE ${REBUILD_TABLE} RENAME TO ${ACTIVE_TABLE}`);
    db.exec(`DROP TABLE IF EXISTS ${OLD_TABLE}`);
    metadata.setMetadata('fts_version', FTS_VERSION);
    deleteMetadata(db, REBUILD_VERSION_KEY);
  });
  tx();
  return true;
}

function reopenCompletedFtsJobs(db: BetterSqlite3.Database): void {
  if (!tableExists(db, 'session_index_jobs')) return;
  db.exec(`
    UPDATE session_index_jobs
    SET status = 'pending',
        retry_count = 0,
        last_error = NULL,
        updated_at = datetime('now')
    WHERE job_kind = 'fts' AND status = 'completed'
  `);
}

function recoverableFtsJobCount(db: BetterSqlite3.Database): number {
  if (!tableExists(db, 'session_index_jobs')) return 0;
  const row = db
    .prepare(`
      SELECT COUNT(*) AS count FROM session_index_jobs
      WHERE job_kind = 'fts' AND status IN ('pending', 'failed_retryable')
    `)
    .get() as { count: number };
  return row.count;
}

function sessionCount(db: BetterSqlite3.Database): number {
  if (!tableExists(db, 'sessions')) return 0;
  const row = db.prepare('SELECT COUNT(*) AS count FROM sessions').get() as {
    count: number;
  };
  return row.count;
}

function deleteIfExists(db: BetterSqlite3.Database, table: string): void {
  if (tableExists(db, table)) db.exec(`DELETE FROM ${table}`);
}

function deleteMetadata(db: BetterSqlite3.Database, key: string): void {
  if (tableExists(db, 'metadata')) {
    db.prepare('DELETE FROM metadata WHERE key = ?').run(key);
  }
}

function tableExists(db: BetterSqlite3.Database, table: string): boolean {
  return (
    db
      .prepare(
        "SELECT 1 FROM sqlite_master WHERE type IN ('table', 'view') AND name = ?",
      )
      .get(table) !== undefined
  );
}
```

Update `src/core/db/migration.ts`:

```ts
import {
  applyFtsRebuildPolicy,
  createSessionsFtsTable,
  FTS_VERSION,
} from './fts-rebuild-policy.js';
```

Replace the inline `CREATE VIRTUAL TABLE IF NOT EXISTS sessions_fts...` block with:

```ts
createSessionsFtsTable(db, 'sessions_fts', { ifNotExists: true });
```

Replace the inline `ftsVersion !== FTS_VERSION` transaction with:

```ts
applyFtsRebuildPolicy(db, { getMetadata, setMetadata });
```

- [x] **Step 4: Run migration tests and verify they pass**

Run:

```bash
npx vitest run tests/core/db-migration.test.ts
```

Expected: PASS.

- [x] **Step 5: Commit Task 1**

```bash
git add src/core/db/fts-rebuild-policy.ts src/core/db/migration.ts tests/core/db-migration.test.ts
git commit -m "feat(db): start fts table-swap rebuilds"
```

## Task 2: Dual Write And Dual Delete FTS Content

**Files:**
- Modify: `src/core/db/fts-repo.ts`
- Modify: `src/core/db/database.ts`
- Modify: `src/core/db/session-repo.ts`
- Modify: `src/core/db/maintenance.ts`
- Test: `tests/core/db.test.ts`
- Test: `tests/core/maintenance.test.ts`

- [x] **Step 1: Write failing dual-write and dual-delete tests**

Add tests to `tests/core/db.test.ts`:

```ts
it('dual-writes replaceFtsContent while an FTS rebuild is pending', () => {
  db.setMetadata('fts_rebuild_version', '3');
  db.raw.exec(`
    CREATE VIRTUAL TABLE sessions_fts_rebuild USING fts5(
      session_id UNINDEXED,
      content,
      tokenize='trigram case_sensitive 0'
    )
  `);

  db.replaceFtsContent('session-001', ['fresh searchable text']);

  expect(db.getFtsContent('session-001')).toEqual(['fresh searchable text']);
  expect(
    db.raw
      .prepare('SELECT content FROM sessions_fts_rebuild WHERE session_id = ?')
      .pluck()
      .all('session-001'),
  ).toEqual(['fresh searchable text']);
});

it('dual-writes indexSessionContent while an FTS rebuild is pending', () => {
  db.setMetadata('fts_rebuild_version', '3');
  db.raw.exec(`
    CREATE VIRTUAL TABLE sessions_fts_rebuild USING fts5(
      session_id UNINDEXED,
      content,
      tokenize='trigram case_sensitive 0'
    )
  `);

  db.indexSessionContent('session-001', [
    { role: 'user', content: 'hello rebuild' },
    { role: 'assistant', content: 'answer rebuild' },
  ]);

  expect(db.getFtsContent('session-001')).toEqual([
    'hello rebuild',
    'answer rebuild',
  ]);
  expect(
    db.raw
      .prepare('SELECT content FROM sessions_fts_rebuild WHERE session_id = ? ORDER BY rowid')
      .pluck()
      .all('session-001'),
  ).toEqual(['hello rebuild', 'answer rebuild']);
});

it('deletes index artifacts from active and rebuild FTS tables', () => {
  db.upsertSession(mockSession);
  db.setMetadata('fts_rebuild_version', '3');
  db.raw.exec(`
    CREATE VIRTUAL TABLE sessions_fts_rebuild USING fts5(
      session_id UNINDEXED,
      content,
      tokenize='trigram case_sensitive 0'
    )
  `);
  db.replaceFtsContent('session-001', ['delete me']);

  db.deleteIndexArtifacts('session-001');

  expect(db.getFtsContent('session-001')).toEqual([]);
  expect(
    db.raw
      .prepare('SELECT content FROM sessions_fts_rebuild WHERE session_id = ?')
      .all('session-001'),
  ).toEqual([]);
});

it('deleteSession removes active and rebuild FTS rows in one transaction', () => {
  db.upsertSession(mockSession);
  db.setMetadata('fts_rebuild_version', '3');
  db.raw.exec(`
    CREATE VIRTUAL TABLE sessions_fts_rebuild USING fts5(
      session_id UNINDEXED,
      content,
      tokenize='trigram case_sensitive 0'
    )
  `);
  db.replaceFtsContent('session-001', ['delete session text']);

  db.deleteSession('session-001');

  expect(db.getSession('session-001')).toBeNull();
  expect(db.getFtsContent('session-001')).toEqual([]);
  expect(
    db.raw
      .prepare('SELECT content FROM sessions_fts_rebuild WHERE session_id = ?')
      .all('session-001'),
  ).toEqual([]);
});
```

Add a maintenance test to `tests/core/maintenance.test.ts` that creates
`sessions_fts_rebuild`, inserts a subagent row into both active and rebuild
tables, runs `downgradeSubagentTiers(db.raw)`, and expects both tables to have no
row for that subagent session.

```ts
it('removes subagent FTS rows from active and rebuild tables', () => {
  db.raw.exec(`
    CREATE VIRTUAL TABLE sessions_fts_rebuild USING fts5(
      session_id UNINDEXED,
      content,
      tokenize='trigram case_sensitive 0'
    );
    INSERT INTO sessions (
      id,
      source,
      start_time,
      cwd,
      file_path,
      agent_role,
      tier
    ) VALUES (
      'subagent-fts',
      'codex',
      '2026-03-18T11:00:00Z',
      '/repo',
      '/tmp/subagent.jsonl',
      'subagent',
      'lite'
    );
    INSERT INTO sessions_fts(session_id, content)
    VALUES ('subagent-fts', 'active subagent text');
    INSERT INTO sessions_fts_rebuild(session_id, content)
    VALUES ('subagent-fts', 'rebuild subagent text');
  `);
  db.setMetadata('fts_rebuild_version', '3');

  expect(downgradeSubagentTiers(db.raw)).toBe(1);

  expect(
    db.raw
      .prepare('SELECT content FROM sessions_fts WHERE session_id = ?')
      .all('subagent-fts'),
  ).toEqual([]);
  expect(
    db.raw
      .prepare('SELECT content FROM sessions_fts_rebuild WHERE session_id = ?')
      .all('subagent-fts'),
  ).toEqual([]);
});
```

- [x] **Step 2: Run tests and verify they fail**

Run:

```bash
npx vitest run tests/core/db.test.ts tests/core/maintenance.test.ts -t "dual|subagent"
```

Expected: FAIL because rebuild table is not yet updated/deleted.

- [x] **Step 3: Implement dual-write / dual-delete helpers**

Extend `src/core/db/fts-rebuild-policy.ts`:

```ts
export function replaceFtsContentForRebuild(
  db: BetterSqlite3.Database,
  sessionId: string,
  contents: string[],
): void {
  const tx = db.transaction(() => {
    replaceFtsContentInTable(db, ACTIVE_TABLE, sessionId, contents);
    if (rebuildIsPending(db) && tableExists(db, REBUILD_TABLE)) {
      replaceFtsContentInTable(db, REBUILD_TABLE, sessionId, contents);
    }
  });
  tx();
}

export function deleteFtsContentForRebuild(
  db: BetterSqlite3.Database,
  sessionId: string,
): void {
  const tx = db.transaction(() => {
    deleteFtsContentInTable(db, ACTIVE_TABLE, sessionId);
    if (rebuildIsPending(db) && tableExists(db, REBUILD_TABLE)) {
      deleteFtsContentInTable(db, REBUILD_TABLE, sessionId);
    }
  });
  tx();
}

export function deleteSubagentFtsForRebuild(db: BetterSqlite3.Database): void {
  const tx = db.transaction(() => {
    db.exec(
      "DELETE FROM sessions_fts WHERE session_id IN (SELECT id FROM sessions WHERE agent_role = 'subagent')",
    );
    if (rebuildIsPending(db) && tableExists(db, REBUILD_TABLE)) {
      db.exec(
        "DELETE FROM sessions_fts_rebuild WHERE session_id IN (SELECT id FROM sessions WHERE agent_role = 'subagent')",
      );
    }
  });
  tx();
}

function replaceFtsContentInTable(
  db: BetterSqlite3.Database,
  table: typeof ACTIVE_TABLE | typeof REBUILD_TABLE,
  sessionId: string,
  contents: string[],
): void {
  deleteFtsContentInTable(db, table, sessionId);
  const insert = db.prepare(`INSERT INTO ${table}(session_id, content) VALUES (?, ?)`);
  for (const content of contents) {
    if (content.trim()) insert.run(sessionId, content);
  }
}

function deleteFtsContentInTable(
  db: BetterSqlite3.Database,
  table: typeof ACTIVE_TABLE | typeof REBUILD_TABLE,
  sessionId: string,
): void {
  db.prepare(`DELETE FROM ${table} WHERE session_id = ?`).run(sessionId);
}

function rebuildIsPending(db: BetterSqlite3.Database): boolean {
  if (!tableExists(db, 'metadata')) return false;
  return (
    db
      .prepare('SELECT value FROM metadata WHERE key = ?')
      .pluck()
      .get(REBUILD_VERSION_KEY) === FTS_VERSION
  );
}
```

Update `src/core/db/fts-repo.ts` so `indexSessionContent` and
`replaceFtsContent` call `replaceFtsContentForRebuild`.

Update `src/core/db/database.ts` and `src/core/db/session-repo.ts` so direct FTS
deletes call `deleteFtsContentForRebuild`.

Update `src/core/db/maintenance.ts` so subagent FTS cleanup calls
`deleteSubagentFtsForRebuild`.

- [x] **Step 4: Run targeted tests and verify they pass**

Run:

```bash
npx vitest run tests/core/db.test.ts tests/core/maintenance.test.ts
```

Expected: PASS.

- [x] **Step 5: Commit Task 2**

```bash
git add src/core/db/fts-rebuild-policy.ts src/core/db/fts-repo.ts src/core/db/database.ts src/core/db/session-repo.ts src/core/db/maintenance.ts tests/core/db.test.ts tests/core/maintenance.test.ts
git commit -m "fix(db): dual-write pending fts rebuild content"
```

## Task 3: Finalize Rebuild From IndexJobRunner

**Files:**
- Modify: `src/core/index-job-runner.ts`
- Test: `tests/core/index-job-runner.test.ts`

- [x] **Step 1: Write failing finalization tests**

Add tests to `tests/core/index-job-runner.test.ts`:

```ts
it('finalizes a pending FTS rebuild after the last FTS job completes', async () => {
  db.upsertAuthoritativeSnapshot({
    id: 'sess-finalize',
    source: 'codex',
    authoritativeNode: 'local',
    syncVersion: 1,
    snapshotHash: 'hash-finalize',
    indexedAt: '2026-03-18T12:00:00Z',
    sourceLocator: '/tmp/rollout.jsonl',
    startTime: '2026-03-18T11:00:00Z',
    cwd: '/repo',
    messageCount: 1,
    userMessageCount: 1,
    assistantMessageCount: 0,
    toolMessageCount: 0,
    systemMessageCount: 0,
    summary: 'final active text',
  });
  db.replaceFtsContent('sess-finalize', ['final active text']);
  db.setMetadata('fts_version', '2');
  db.setMetadata('fts_rebuild_version', '3');
  db.raw.exec(`
    CREATE VIRTUAL TABLE sessions_fts_rebuild USING fts5(
      session_id UNINDEXED,
      content,
      tokenize='trigram case_sensitive 0'
    );
    INSERT INTO sessions_fts_rebuild(session_id, content)
    VALUES ('sess-finalize', 'final active text');
  `);
  db.insertIndexJobs('sess-finalize', 1, ['fts']);

  const runner = new IndexJobRunner(db, mockStore, mockClient);
  await runner.runRecoverableJobs();

  expect(db.getMetadata('fts_version')).toBe('3');
  expect(db.getMetadata('fts_rebuild_version')).toBeNull();
  expect(db.getFtsContent('sess-finalize')).toEqual(['final active text']);
  expect(
    db.raw
      .prepare("SELECT name FROM sqlite_master WHERE type='table' AND name='sessions_fts_rebuild'")
      .get(),
  ).toBeUndefined();
});

it('preserves copied active FTS rows when reopened jobs only mark completed', async () => {
  db.upsertAuthoritativeSnapshot({
    id: 'sess-copy',
    source: 'codex',
    authoritativeNode: 'local',
    syncVersion: 1,
    snapshotHash: 'hash-copy',
    indexedAt: '2026-03-18T12:00:00Z',
    sourceLocator: '/tmp/rollout.jsonl',
    startTime: '2026-03-18T11:00:00Z',
    cwd: '/repo',
    messageCount: 1,
    userMessageCount: 1,
    assistantMessageCount: 0,
    toolMessageCount: 0,
    systemMessageCount: 0,
    summary: 'summary fallback',
  });
  db.replaceFtsContent('sess-copy', ['full copied transcript text']);
  db.setMetadata('fts_version', '2');
  db.setMetadata('fts_rebuild_version', '3');
  db.raw.exec(`
    CREATE VIRTUAL TABLE sessions_fts_rebuild USING fts5(
      session_id UNINDEXED,
      content,
      tokenize='trigram case_sensitive 0'
    );
    INSERT INTO sessions_fts_rebuild(session_id, content)
    VALUES ('sess-copy', 'full copied transcript text');
  `);
  db.insertIndexJobs('sess-copy', 1, ['fts']);

  const runner = new IndexJobRunner(db, mockStore, mockClient);
  await runner.runRecoverableJobs();

  expect(db.getFtsContent('sess-copy')).toEqual(['full copied transcript text']);
});
```

- [x] **Step 2: Run tests and verify they fail**

Run:

```bash
npx vitest run tests/core/index-job-runner.test.ts -t "finalizes|preserves copied"
```

Expected: FAIL because `IndexJobRunner` does not finalize the rebuild.

- [x] **Step 3: Wire finalization**

Update `src/core/index-job-runner.ts` to call finalization after FTS jobs that
leave recoverable status.

Inside `runFtsJob`, after each `markIndexJobCompleted` path and after replacing
content:

```ts
this.db.markIndexJobCompleted(job.id);
this.db.finalizeFtsRebuildIfReady();
return;
```

Add `Database.finalizeFtsRebuildIfReady()` in `src/core/db/database.ts`:

```ts
import { finalizeFtsRebuildIfReady } from './fts-rebuild-policy.js';

finalizeFtsRebuildIfReady(): boolean {
  return finalizeFtsRebuildIfReady(this.db, {
    getMetadata: (key) => this.getMetadata(key),
    setMetadata: (key, value) => this.setMetadata(key, value),
  });
}
```

- [x] **Step 4: Run index job tests and verify they pass**

Run:

```bash
npx vitest run tests/core/index-job-runner.test.ts
```

Expected: PASS.

- [x] **Step 5: Commit Task 3**

```bash
git add src/core/index-job-runner.ts src/core/db/database.ts tests/core/index-job-runner.test.ts
git commit -m "fix(index): finalize pending fts rebuilds"
```

## Task 4: Documentation And Full Verification

**Files:**
- Modify: `CHANGELOG.md`
- Modify: `.memory`

- [x] **Step 1: Update durable docs**

Add a new `[Unreleased]` entry to `CHANGELOG.md`:

```md
### TypeScript FTS table-swap rebuild (2026-06-04, Codex)

- Added a TypeScript `sessions_fts` rebuild policy with a copied shadow table,
  pending rebuild metadata, dual-write/dual-delete behavior, and atomic swap
  finalization.
- Kept active FTS search available during rebuilds and covered repeated startup
  idempotency so shadow rows are not duplicated.
- Verified migration, write/delete, maintenance, and index-job finalization paths.
```

Add a matching top entry to `.memory` with branch, files, checks run, and
remaining risk that `insights_fts` table-swap is intentionally out of scope.

- [x] **Step 2: Run full local verification**

Run:

```bash
npx vitest run tests/core/db-migration.test.ts tests/core/db.test.ts tests/core/maintenance.test.ts tests/core/index-job-runner.test.ts
npm run lint
npm run typecheck:test
npm run build
npm test
git diff --check
```

Expected:

- targeted Vitest: PASS
- lint: PASS
- typecheck: PASS
- build: PASS
- full test suite: PASS
- diff check: no output

- [x] **Step 3: Commit docs**

```bash
git add CHANGELOG.md .memory
git commit -m "docs(memory): record fts table-swap rebuild"
```

- [x] **Step 4: Push and open PR**

```bash
git status --short
git push -u origin feat/fts-table-swap-rebuild
gh pr create --base main --head feat/fts-table-swap-rebuild \
  --title "feat(db): add fts table-swap rebuild" \
  --body-file -
```

PR body must include summary and the exact verification commands from Step 2.

- [x] **Step 5: Watch CI**

Run:

```bash
gh pr view --json number,url,mergeStateStatus,statusCheckRollup
gh run watch <run-id> --exit-status
```

Expected: required checks pass; `ui-test-full` may be skipped on PR by workflow
condition.
