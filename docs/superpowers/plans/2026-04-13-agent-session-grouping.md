# Agent Session Grouping & Collapsing — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Group agent sessions under their parent session with collapsible UI, filtering agents from the main timeline.

**Architecture:** Add `parent_session_id` + `suggested_parent_id` columns to sessions table. Three-layer detection: path-based (Claude Code subagents), content heuristic (Gemini/Codex dispatched agents), manual override. Swift UI gets collapsible parent cards in HomeView and SessionListView.

**Tech Stack:** TypeScript (Vitest, better-sqlite3, Hono), Swift 5.9 (SwiftUI, GRDB)

**Spec:** `docs/superpowers/specs/2026-04-13-agent-session-grouping-design.md`

---

## File Structure

### New files
| File | Responsibility |
|------|---------------|
| `src/core/db/parent-link-repo.ts` | Parent link CRUD, validation, child queries, suggested parent queries |
| `src/core/parent-detection.ts` | Layer 2: dispatch pattern detection + candidate parent scoring |
| `tests/core/db/parent-link-repo.test.ts` | Tests for parent link repo |
| `tests/core/parent-detection.test.ts` | Tests for heuristic detection |
| `tests/web/parent-link-api.test.ts` | Tests for link/unlink API endpoints |
| `macos/Engram/Components/ExpandableSessionCard.swift` | Disclosure-triangle parent card + compact child rows |

### Modified files
| File | Changes |
|------|---------|
| `src/core/db/migration.ts` | Add 4 columns, 2 indexes, 1 trigger to sessions table |
| `src/core/db/session-repo.ts` | Update `rowToSession()` to include new fields |
| `src/core/db/database.ts` | Facade methods for parent link repo |
| `src/core/db/maintenance.ts` | `backfillParentLinks()` (Pass 1 + tier upgrade) |
| `src/core/db/types.ts` | No change needed — parent link types in own module |
| `src/adapters/types.ts` | Add `parentSessionId?` to `SessionInfo` |
| `src/adapters/claude-code.ts` | Extract parent ID from subagent path in `parseSessionInfo()` |
| `src/web.ts` | 4 new HTTP endpoints for link management |
| `src/daemon.ts` | Wire backfill + Layer 2 scan into post-indexing maintenance |
| `macos/Engram/Models/Session.swift` | Add `parentSessionId`, `suggestedParentId`, `linkSource` |
| `macos/Engram/Core/Database.swift` | New read methods + update `recentSessions()` |
| `macos/Engram/Core/DaemonClient.swift` | Link/unlink/confirm/dismiss API methods |
| `macos/Engram/Views/Pages/HomeView.swift` | Use expandable cards, load children on expand |
| `macos/Engram/Views/SessionListView.swift` | Grouped list with agent filter interaction |
| `macos/Engram/Views/SessionDetailView.swift` | Parent breadcrumb + child list |
| `macos/Engram/Components/SessionCard.swift` | No changes (kept as-is for non-parent cards) |

---

### Task 1: Schema Migration

**Files:**
- Modify: `src/core/db/migration.ts:12-100`
- Test: `tests/core/db-migration.test.ts` (existing, add cases)

- [ ] **Step 1: Write failing test — new columns exist after migration**

In `tests/core/db-migration.test.ts`, add:

```typescript
it('adds parent_session_id, suggested_parent_id, link_source, link_checked_at columns', () => {
  const db = new Database(join(tmpDir, 'test-parent-cols.sqlite'));
  const cols = db.raw
    .prepare('PRAGMA table_info(sessions)')
    .all() as { name: string }[];
  const colNames = cols.map((c) => c.name);
  expect(colNames).toContain('parent_session_id');
  expect(colNames).toContain('suggested_parent_id');
  expect(colNames).toContain('link_source');
  expect(colNames).toContain('link_checked_at');
  db.close();
});

it('creates orphan protection trigger', () => {
  const db = new Database(join(tmpDir, 'test-trigger.sqlite'));
  const triggers = db.raw
    .prepare("SELECT name FROM sqlite_master WHERE type='trigger'")
    .all() as { name: string }[];
  expect(triggers.map((t) => t.name)).toContain('trg_sessions_parent_cascade');
  db.close();
});

it('creates composite indexes for parent queries', () => {
  const db = new Database(join(tmpDir, 'test-indexes.sqlite'));
  const indexes = db.raw
    .prepare("SELECT name FROM sqlite_master WHERE type='index'")
    .all() as { name: string }[];
  const names = indexes.map((i) => i.name);
  expect(names).toContain('idx_sessions_parent');
  expect(names).toContain('idx_sessions_suggested_parent');
  db.close();
});
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `npm test -- tests/core/db-migration.test.ts`
Expected: FAIL — columns, trigger, and indexes don't exist yet.

- [ ] **Step 3: Add columns to ALTER TABLE migration block**

In `src/core/db/migration.ts`, after line 57 (`quality_score` block), add:

```typescript
    if (!colNames.has('parent_session_id'))
      db.exec('ALTER TABLE sessions ADD COLUMN parent_session_id TEXT');
    if (!colNames.has('suggested_parent_id'))
      db.exec('ALTER TABLE sessions ADD COLUMN suggested_parent_id TEXT');
    if (!colNames.has('link_source'))
      db.exec('ALTER TABLE sessions ADD COLUMN link_source TEXT');
    if (!colNames.has('link_checked_at'))
      db.exec('ALTER TABLE sessions ADD COLUMN link_checked_at TEXT');
```

- [ ] **Step 4: Add columns to base CREATE TABLE**

In `src/core/db/migration.ts`, in the `CREATE TABLE IF NOT EXISTS sessions` block (after line 92 `quality_score`), add:

```sql
      parent_session_id TEXT,
      suggested_parent_id TEXT,
      link_source TEXT,
      link_checked_at TEXT
```

- [ ] **Step 5: Add indexes and trigger after CREATE TABLE block**

In `src/core/db/migration.ts`, after the existing index declarations (after line 100), add:

```typescript
    CREATE INDEX IF NOT EXISTS idx_sessions_parent ON sessions(parent_session_id, start_time DESC);
    CREATE INDEX IF NOT EXISTS idx_sessions_suggested_parent ON sessions(suggested_parent_id, start_time DESC);

    CREATE TRIGGER IF NOT EXISTS trg_sessions_parent_cascade
    AFTER DELETE ON sessions
    BEGIN
      UPDATE sessions SET parent_session_id = NULL, link_source = NULL, tier = NULL
        WHERE parent_session_id = OLD.id;
      UPDATE sessions SET suggested_parent_id = NULL
        WHERE suggested_parent_id = OLD.id;
    END;
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `npm test -- tests/core/db-migration.test.ts`
Expected: ALL PASS

- [ ] **Step 7: Commit**

```bash
git add src/core/db/migration.ts tests/core/db-migration.test.ts
git commit -m "feat: add parent_session_id schema migration + orphan trigger"
```

---

### Task 2: Parent Link Repo — Validation & CRUD

**Files:**
- Create: `src/core/db/parent-link-repo.ts`
- Create: `tests/core/db/parent-link-repo.test.ts`

- [ ] **Step 1: Write failing tests for validation and CRUD**

Create `tests/core/db/parent-link-repo.test.ts`:

```typescript
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { Database } from '../../../src/core/db/database.js';
import {
  validateParentLink,
  setParentSession,
  clearParentSession,
  confirmSuggestion,
  setSuggestedParent,
  clearSuggestedParent,
  childSessions,
  childCount,
  suggestedChildSessions,
  suggestedChildCount,
} from '../../../src/core/db/parent-link-repo.js';

describe('parent-link-repo', () => {
  let db: Database;
  let tmpDir: string;

  beforeEach(() => {
    tmpDir = mkdtempSync(join(tmpdir(), 'parent-link-test-'));
    db = new Database(join(tmpDir, 'test.sqlite'));
    // Insert test sessions
    db.upsertSession({
      id: 'parent-1', source: 'claude-code', startTime: '2026-04-13T10:00:00Z',
      cwd: '/test', messageCount: 10, userMessageCount: 5, assistantMessageCount: 5,
      toolMessageCount: 0, systemMessageCount: 0, filePath: '/test/parent.jsonl', sizeBytes: 100,
    });
    db.upsertSession({
      id: 'child-1', source: 'gemini-cli', startTime: '2026-04-13T10:05:00Z',
      cwd: '/test', messageCount: 5, userMessageCount: 2, assistantMessageCount: 3,
      toolMessageCount: 0, systemMessageCount: 0, filePath: '/test/child1.jsonl', sizeBytes: 50,
      agentRole: 'subagent',
    });
    db.upsertSession({
      id: 'child-2', source: 'codex', startTime: '2026-04-13T10:10:00Z',
      cwd: '/test', messageCount: 3, userMessageCount: 1, assistantMessageCount: 2,
      toolMessageCount: 0, systemMessageCount: 0, filePath: '/test/child2.jsonl', sizeBytes: 30,
    });
  });

  afterEach(() => {
    db.close();
    rmSync(tmpDir, { recursive: true });
  });

  describe('validateParentLink', () => {
    it('rejects self-link', () => {
      expect(validateParentLink(db.raw, 'parent-1', 'parent-1')).toBe('self-link');
    });

    it('rejects non-existent parent', () => {
      expect(validateParentLink(db.raw, 'child-1', 'nonexistent')).toBe('parent-not-found');
    });

    it('rejects depth > 1', () => {
      setParentSession(db.raw, 'child-1', 'parent-1', 'path');
      expect(validateParentLink(db.raw, 'child-2', 'child-1')).toBe('depth-exceeded');
    });

    it('accepts valid parent link', () => {
      expect(validateParentLink(db.raw, 'child-1', 'parent-1')).toBe('ok');
    });
  });

  describe('setParentSession', () => {
    it('sets parent and link_source', () => {
      setParentSession(db.raw, 'child-1', 'parent-1', 'path');
      const row = db.raw.prepare('SELECT parent_session_id, link_source FROM sessions WHERE id = ?').get('child-1') as Record<string, unknown>;
      expect(row.parent_session_id).toBe('parent-1');
      expect(row.link_source).toBe('path');
    });

    it('upgrades tier from skip to lite on link', () => {
      db.raw.prepare('UPDATE sessions SET tier = ? WHERE id = ?').run('skip', 'child-1');
      setParentSession(db.raw, 'child-1', 'parent-1', 'path');
      const row = db.raw.prepare('SELECT tier FROM sessions WHERE id = ?').get('child-1') as Record<string, unknown>;
      expect(row.tier).toBe('lite');
    });
  });

  describe('clearParentSession', () => {
    it('clears parent and sets link_source to manual', () => {
      setParentSession(db.raw, 'child-1', 'parent-1', 'path');
      clearParentSession(db.raw, 'child-1');
      const row = db.raw.prepare('SELECT parent_session_id, link_source FROM sessions WHERE id = ?').get('child-1') as Record<string, unknown>;
      expect(row.parent_session_id).toBeNull();
      expect(row.link_source).toBe('manual');
    });
  });

  describe('child queries', () => {
    it('childSessions returns paginated children', () => {
      setParentSession(db.raw, 'child-1', 'parent-1', 'path');
      setParentSession(db.raw, 'child-2', 'parent-1', 'manual');
      const children = childSessions(db.raw, 'parent-1', 20, 0);
      expect(children).toHaveLength(2);
      expect(children[0].id).toBe('child-1'); // earlier start_time first
    });

    it('childCount returns batch counts', () => {
      setParentSession(db.raw, 'child-1', 'parent-1', 'path');
      const counts = childCount(db.raw, ['parent-1', 'nonexistent']);
      expect(counts.get('parent-1')).toBe(1);
      expect(counts.has('nonexistent')).toBe(false);
    });
  });

  describe('suggested parent', () => {
    it('setSuggestedParent writes suggested_parent_id and link_checked_at', () => {
      setSuggestedParent(db.raw, 'child-2', 'parent-1');
      const row = db.raw.prepare('SELECT suggested_parent_id, link_checked_at FROM sessions WHERE id = ?').get('child-2') as Record<string, unknown>;
      expect(row.suggested_parent_id).toBe('parent-1');
      expect(row.link_checked_at).toBeTruthy();
    });

    it('clearSuggestedParent uses conditional update', () => {
      setSuggestedParent(db.raw, 'child-2', 'parent-1');
      const cleared = clearSuggestedParent(db.raw, 'child-2', 'parent-1');
      expect(cleared).toBe(true);
      const row = db.raw.prepare('SELECT suggested_parent_id FROM sessions WHERE id = ?').get('child-2') as Record<string, unknown>;
      expect(row.suggested_parent_id).toBeNull();
    });

    it('clearSuggestedParent rejects stale expected value', () => {
      setSuggestedParent(db.raw, 'child-2', 'parent-1');
      const cleared = clearSuggestedParent(db.raw, 'child-2', 'wrong-id');
      expect(cleared).toBe(false);
    });

    it('suggestedChildSessions returns suggested children', () => {
      setSuggestedParent(db.raw, 'child-2', 'parent-1');
      const suggested = suggestedChildSessions(db.raw, 'parent-1');
      expect(suggested).toHaveLength(1);
      expect(suggested[0].id).toBe('child-2');
    });
  });

  describe('confirmSuggestion', () => {
    it('promotes suggested parent to confirmed', () => {
      setSuggestedParent(db.raw, 'child-2', 'parent-1');
      const result = confirmSuggestion(db.raw, 'child-2');
      expect(result.ok).toBe(true);
      const row = db.raw.prepare('SELECT parent_session_id, suggested_parent_id, link_source FROM sessions WHERE id = ?')
        .get('child-2') as Record<string, unknown>;
      expect(row.parent_session_id).toBe('parent-1');
      expect(row.suggested_parent_id).toBeNull();
      expect(row.link_source).toBe('manual');
    });

    it('rejects when no suggestion exists', () => {
      const result = confirmSuggestion(db.raw, 'child-2');
      expect(result.ok).toBe(false);
      expect(result.error).toBe('no-suggestion');
    });

    it('rejects when suggested parent no longer exists', () => {
      setSuggestedParent(db.raw, 'child-2', 'parent-1');
      db.raw.prepare('DELETE FROM sessions WHERE id = ?').run('parent-1');
      const result = confirmSuggestion(db.raw, 'child-2');
      expect(result.ok).toBe(false);
    });

    it('upgrades tier from skip to lite on confirm', () => {
      db.raw.prepare('UPDATE sessions SET tier = ? WHERE id = ?').run('skip', 'child-2');
      setSuggestedParent(db.raw, 'child-2', 'parent-1');
      confirmSuggestion(db.raw, 'child-2');
      const row = db.raw.prepare('SELECT tier FROM sessions WHERE id = ?').get('child-2') as Record<string, unknown>;
      expect(row.tier).toBe('lite');
    });
  });

  describe('orphan trigger', () => {
    it('nullifies parent_session_id when parent is deleted', () => {
      setParentSession(db.raw, 'child-1', 'parent-1', 'path');
      db.raw.prepare('DELETE FROM sessions WHERE id = ?').run('parent-1');
      const row = db.raw.prepare('SELECT parent_session_id, tier FROM sessions WHERE id = ?').get('child-1') as Record<string, unknown>;
      expect(row.parent_session_id).toBeNull();
      expect(row.tier).toBeNull(); // trigger sets tier=NULL for re-evaluation
    });
  });
});
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `npm test -- tests/core/db/parent-link-repo.test.ts`
Expected: FAIL — module doesn't exist yet.

- [ ] **Step 3: Implement parent-link-repo.ts**

Create `src/core/db/parent-link-repo.ts`:

```typescript
// src/core/db/parent-link-repo.ts — parent session link management
import type BetterSqlite3 from 'better-sqlite3';
import type { SessionInfo } from '../../adapters/types.js';

type ValidationResult = 'ok' | 'self-link' | 'parent-not-found' | 'depth-exceeded';

export function validateParentLink(
  db: BetterSqlite3.Database,
  sessionId: string,
  parentId: string,
): ValidationResult {
  if (sessionId === parentId) return 'self-link';

  const parent = db
    .prepare('SELECT id, parent_session_id FROM sessions WHERE id = ?')
    .get(parentId) as { id: string; parent_session_id: string | null } | undefined;

  if (!parent) return 'parent-not-found';
  if (parent.parent_session_id != null) return 'depth-exceeded';

  return 'ok';
}

export function setParentSession(
  db: BetterSqlite3.Database,
  sessionId: string,
  parentId: string,
  linkSource: 'path' | 'manual',
): void {
  db.prepare(`
    UPDATE sessions
    SET parent_session_id = ?, link_source = ?, link_checked_at = datetime('now'),
        suggested_parent_id = NULL,
        tier = CASE WHEN tier = 'skip' THEN 'lite' ELSE tier END
    WHERE id = ?
  `).run(parentId, linkSource, sessionId);
}

export function clearParentSession(
  db: BetterSqlite3.Database,
  sessionId: string,
): void {
  // Mark as manually unlinked — prevents re-linking by backfill
  // Set tier=NULL so backfillTiers() re-evaluates
  db.prepare(`
    UPDATE sessions
    SET parent_session_id = NULL, link_source = 'manual', tier = NULL
    WHERE id = ?
  `).run(sessionId);
}

export function confirmSuggestion(
  db: BetterSqlite3.Database,
  sessionId: string,
): { ok: boolean; error?: string } {
  const row = db
    .prepare('SELECT suggested_parent_id FROM sessions WHERE id = ?')
    .get(sessionId) as { suggested_parent_id: string | null } | undefined;

  if (!row?.suggested_parent_id) return { ok: false, error: 'no-suggestion' };

  const validation = validateParentLink(db, sessionId, row.suggested_parent_id);
  if (validation !== 'ok') return { ok: false, error: validation };

  setParentSession(db, sessionId, row.suggested_parent_id, 'manual');
  return { ok: true };
}

export function setSuggestedParent(
  db: BetterSqlite3.Database,
  sessionId: string,
  suggestedParentId: string,
): void {
  db.prepare(`
    UPDATE sessions
    SET suggested_parent_id = ?, link_checked_at = datetime('now')
    WHERE id = ?
  `).run(suggestedParentId, sessionId);
}

export function clearSuggestedParent(
  db: BetterSqlite3.Database,
  sessionId: string,
  expectedParentId: string,
): boolean {
  const result = db.prepare(`
    UPDATE sessions
    SET suggested_parent_id = NULL, link_checked_at = datetime('now')
    WHERE id = ? AND suggested_parent_id = ?
  `).run(sessionId, expectedParentId);
  return result.changes > 0;
}

function rowToSessionInfo(row: Record<string, unknown>): SessionInfo {
  return {
    id: row.id as string,
    source: row.source as SessionInfo['source'],
    startTime: row.start_time as string,
    endTime: row.end_time as string | undefined,
    cwd: row.cwd as string,
    project: row.project as string | undefined,
    model: row.model as string | undefined,
    messageCount: row.message_count as number,
    userMessageCount: row.user_message_count as number,
    assistantMessageCount: (row.assistant_message_count as number) ?? 0,
    toolMessageCount: (row.tool_message_count as number) ?? 0,
    systemMessageCount: (row.system_message_count as number) ?? 0,
    summary: row.summary as string | undefined,
    filePath: row.file_path as string,
    sizeBytes: row.size_bytes as number,
    indexedAt: row.indexed_at as string | undefined,
    agentRole: row.agent_role as string | undefined,
    tier: row.tier as string | undefined,
    parentSessionId: row.parent_session_id as string | undefined,
    suggestedParentId: row.suggested_parent_id as string | undefined,
  };
}

export function childSessions(
  db: BetterSqlite3.Database,
  parentId: string,
  limit: number,
  offset: number,
): SessionInfo[] {
  const rows = db.prepare(`
    SELECT * FROM sessions
    WHERE parent_session_id = ? AND hidden_at IS NULL
    ORDER BY start_time ASC
    LIMIT ? OFFSET ?
  `).all(parentId, limit, offset) as Record<string, unknown>[];
  return rows.map(rowToSessionInfo);
}

export function childCount(
  db: BetterSqlite3.Database,
  parentIds: string[],
): Map<string, number> {
  if (parentIds.length === 0) return new Map();
  const placeholders = parentIds.map(() => '?').join(',');
  const rows = db.prepare(`
    SELECT parent_session_id, COUNT(*) as cnt
    FROM sessions
    WHERE parent_session_id IN (${placeholders}) AND hidden_at IS NULL
    GROUP BY parent_session_id
  `).all(...parentIds) as { parent_session_id: string; cnt: number }[];
  return new Map(rows.map((r) => [r.parent_session_id, r.cnt]));
}

export function suggestedChildSessions(
  db: BetterSqlite3.Database,
  parentId: string,
): SessionInfo[] {
  const rows = db.prepare(`
    SELECT * FROM sessions
    WHERE suggested_parent_id = ? AND parent_session_id IS NULL AND hidden_at IS NULL
    ORDER BY start_time ASC
  `).all(parentId) as Record<string, unknown>[];
  return rows.map(rowToSessionInfo);
}

export function suggestedChildCount(
  db: BetterSqlite3.Database,
  parentIds: string[],
): Map<string, number> {
  if (parentIds.length === 0) return new Map();
  const placeholders = parentIds.map(() => '?').join(',');
  const rows = db.prepare(`
    SELECT suggested_parent_id, COUNT(*) as cnt
    FROM sessions
    WHERE suggested_parent_id IN (${placeholders})
      AND parent_session_id IS NULL AND hidden_at IS NULL
    GROUP BY suggested_parent_id
  `).all(...parentIds) as { suggested_parent_id: string; cnt: number }[];
  return new Map(rows.map((r) => [r.suggested_parent_id, r.cnt]));
}
```

- [ ] **Step 4: Update SessionInfo type to include parent fields**

In `src/adapters/types.ts`, after line 41 (`qualityScore`), add:

```typescript
  parentSessionId?: string; // confirmed parent session ID
  suggestedParentId?: string; // Layer 2 heuristic suggestion (advisory)
```

- [ ] **Step 5: Update rowToSession in session-repo.ts**

In `src/core/db/session-repo.ts`, in `rowToSession()` (after line 52), add:

```typescript
    parentSessionId: row.parent_session_id as string | undefined,
    suggestedParentId: row.suggested_parent_id as string | undefined,
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `npm test -- tests/core/db/parent-link-repo.test.ts`
Expected: ALL PASS

- [ ] **Step 7: Commit**

```bash
git add src/core/db/parent-link-repo.ts tests/core/db/parent-link-repo.test.ts src/adapters/types.ts src/core/db/session-repo.ts
git commit -m "feat: parent link repo with validation, CRUD, and child queries"
```

---

### Task 3: Database Facade + Maintenance Backfill

**Files:**
- Modify: `src/core/db/database.ts:330-353`
- Modify: `src/core/db/maintenance.ts`
- Test: `tests/core/db/parent-link-repo.test.ts` (add backfill tests)

- [ ] **Step 1: Write failing test for backfillParentLinks**

Add to `tests/core/db/parent-link-repo.test.ts`:

```typescript
import { backfillParentLinks } from '../../../src/core/db/maintenance.js';

describe('backfillParentLinks', () => {
  it('links subagent sessions to parent via agent_role', () => {
    // Insert parent
    db.upsertSession({
      id: 'sess-abc', source: 'claude-code', startTime: '2026-04-13T10:00:00Z',
      cwd: '/test', messageCount: 10, userMessageCount: 5, assistantMessageCount: 5,
      toolMessageCount: 0, systemMessageCount: 0,
      filePath: '/home/.claude/projects/myproj/sess-abc.jsonl', sizeBytes: 100,
    });
    // Insert subagent whose path encodes parent session ID
    db.raw.prepare(`
      INSERT INTO sessions (id, source, start_time, cwd, file_path, size_bytes, agent_role, message_count, user_message_count)
      VALUES ('agent-xyz', 'claude-code', '2026-04-13T10:05:00Z', '/test',
              '/home/.claude/projects/myproj/sess-abc/subagents/agent-xyz.jsonl', 50, 'subagent', 5, 2)
    `).run();

    const result = backfillParentLinks(db.raw);
    expect(result.linked).toBe(1);

    const row = db.raw.prepare('SELECT parent_session_id, link_source FROM sessions WHERE id = ?')
      .get('agent-xyz') as Record<string, unknown>;
    expect(row.parent_session_id).toBe('sess-abc');
    expect(row.link_source).toBe('path');
  });

  it('skips manually unlinked sessions', () => {
    db.raw.prepare(`
      INSERT INTO sessions (id, source, start_time, cwd, file_path, size_bytes, agent_role, link_source, message_count, user_message_count)
      VALUES ('agent-manual', 'claude-code', '2026-04-13T10:05:00Z', '/test',
              '/home/.claude/projects/myproj/sess-abc/subagents/agent-manual.jsonl', 50, 'subagent', 'manual', 5, 2)
    `).run();

    const result = backfillParentLinks(db.raw);
    expect(result.linked).toBe(0);
  });

  it('upgrades tier from skip to lite for linked sessions', () => {
    db.upsertSession({
      id: 'sess-p', source: 'claude-code', startTime: '2026-04-13T10:00:00Z',
      cwd: '/test', messageCount: 10, userMessageCount: 5, assistantMessageCount: 5,
      toolMessageCount: 0, systemMessageCount: 0,
      filePath: '/home/.claude/projects/myproj/sess-p.jsonl', sizeBytes: 100,
    });
    db.raw.prepare(`
      INSERT INTO sessions (id, source, start_time, cwd, file_path, size_bytes, agent_role, tier, message_count, user_message_count)
      VALUES ('agent-t', 'claude-code', '2026-04-13T10:05:00Z', '/test',
              '/home/.claude/projects/myproj/sess-p/subagents/agent-t.jsonl', 50, 'subagent', 'skip', 5, 2)
    `).run();

    backfillParentLinks(db.raw);

    const row = db.raw.prepare('SELECT tier FROM sessions WHERE id = ?').get('agent-t') as Record<string, unknown>;
    expect(row.tier).toBe('lite');
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `npm test -- tests/core/db/parent-link-repo.test.ts`
Expected: FAIL — `backfillParentLinks` doesn't exist.

- [ ] **Step 3: Implement backfillParentLinks in maintenance.ts**

In `src/core/db/maintenance.ts`, add:

```typescript
import {
  validateParentLink,
  setParentSession,
} from './parent-link-repo.js';

export function backfillParentLinks(
  db: BetterSqlite3.Database,
): { linked: number; tierUpgraded: number } {
  let linked = 0;

  // Pass 1: Link subagent sessions to parent via path parsing
  const candidates = db.prepare(`
    SELECT id, file_path FROM sessions
    WHERE agent_role = 'subagent'
      AND parent_session_id IS NULL
      AND (link_source IS NULL OR link_source != 'manual')
    LIMIT 500
  `).all() as { id: string; file_path: string }[];

  for (const { id, file_path } of candidates) {
    // Extract parent session ID from path:
    // ~/.claude/projects/<project>/<sessionId>/subagents/<agentId>.jsonl
    const match = file_path.match(/\/([^/]+)\/subagents\/[^/]+\.jsonl$/);
    if (!match) continue;

    const parentId = match[1];
    const validation = validateParentLink(db, id, parentId);
    if (validation !== 'ok') continue;

    setParentSession(db, id, parentId, 'path');
    linked++;
  }

  // Tier upgrade pass: ensure all linked children have at least 'lite'
  const tierUpgraded = db.prepare(`
    UPDATE sessions SET tier = 'lite'
    WHERE parent_session_id IS NOT NULL AND tier = 'skip'
  `).run().changes;

  return { linked, tierUpgraded };
}
```

- [ ] **Step 4: Add facade methods to database.ts**

In `src/core/db/database.ts`, add import at top:

```typescript
import * as parentLinks from './parent-link-repo.js';
```

After the maintenance section (after line 353), add:

```typescript
  // --- Parent link repo ---
  validateParentLink(sessionId: string, parentId: string) {
    return parentLinks.validateParentLink(this.db, sessionId, parentId);
  }
  setParentSession(sessionId: string, parentId: string, linkSource: 'path' | 'manual') {
    parentLinks.setParentSession(this.db, sessionId, parentId, linkSource);
  }
  clearParentSession(sessionId: string) {
    parentLinks.clearParentSession(this.db, sessionId);
  }
  confirmSuggestion(sessionId: string) {
    return parentLinks.confirmSuggestion(this.db, sessionId);
  }
  setSuggestedParent(sessionId: string, suggestedParentId: string) {
    parentLinks.setSuggestedParent(this.db, sessionId, suggestedParentId);
  }
  clearSuggestedParent(sessionId: string, expectedParentId: string) {
    return parentLinks.clearSuggestedParent(this.db, sessionId, expectedParentId);
  }
  childSessions(parentId: string, limit = 20, offset = 0) {
    return parentLinks.childSessions(this.db, parentId, limit, offset);
  }
  childCount(parentIds: string[]) {
    return parentLinks.childCount(this.db, parentIds);
  }
  suggestedChildSessions(parentId: string) {
    return parentLinks.suggestedChildSessions(this.db, parentId);
  }
  suggestedChildCount(parentIds: string[]) {
    return parentLinks.suggestedChildCount(this.db, parentIds);
  }
  backfillParentLinks() {
    return maint.backfillParentLinks(this.db);
  }
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `npm test -- tests/core/db/parent-link-repo.test.ts`
Expected: ALL PASS

- [ ] **Step 6: Commit**

```bash
git add src/core/db/maintenance.ts src/core/db/database.ts tests/core/db/parent-link-repo.test.ts
git commit -m "feat: parent link backfill + database facade methods"
```

---

### Task 4: Layer 1 — Claude Code Adapter Path Parsing

**Files:**
- Modify: `src/adapters/claude-code.ts:119-142`
- Test: `tests/adapters/claude-code.test.ts`

- [ ] **Step 1: Write failing test for parentSessionId extraction**

In `tests/adapters/claude-code.test.ts`, add:

```typescript
it('sets parentSessionId for subagent sessions from path', async () => {
  // Create a fixture with subagent path structure
  const subagentDir = join(tmpDir, 'sess-parent123', 'subagents');
  mkdirSync(subagentDir, { recursive: true });
  const subagentPath = join(subagentDir, 'agent-child456.jsonl');

  // Write minimal valid session JSONL
  writeFileSync(subagentPath, [
    JSON.stringify({ type: 'user', sessionId: 'sess-parent123', agentId: 'agent-child456', cwd: '/test', timestamp: '2026-04-13T10:00:00Z', message: { content: 'test' } }),
    JSON.stringify({ type: 'assistant', sessionId: 'sess-parent123', timestamp: '2026-04-13T10:01:00Z', message: { content: 'ok' } }),
  ].join('\n'));

  const adapter = new ClaudeCodeAdapter();
  const info = await adapter.parseSessionInfo(subagentPath);
  expect(info).not.toBeNull();
  expect(info!.id).toBe('agent-child456');
  expect(info!.agentRole).toBe('subagent');
  expect(info!.parentSessionId).toBe('sess-parent123');
});

it('does not set parentSessionId for regular sessions', async () => {
  const info = await adapter.parseSessionInfo(FIXTURE);
  expect(info).not.toBeNull();
  expect(info!.parentSessionId).toBeUndefined();
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `npm test -- tests/adapters/claude-code.test.ts`
Expected: FAIL — `parentSessionId` is undefined for subagent.

- [ ] **Step 3: Extract parent session ID from subagent path**

In `src/adapters/claude-code.ts`, modify the return block starting at line 126:

```typescript
      // Extract parent session ID from subagent path
      let parentSessionId: string | undefined;
      if (isSubagent) {
        const match = filePath.match(/\/([^/]+)\/subagents\/[^/]+\.jsonl$/);
        if (match) parentSessionId = match[1];
      }

      return {
        id,
        source,
        startTime,
        endTime: endTime !== startTime ? endTime : undefined,
        cwd,
        model: detectedModel || undefined,
        messageCount: userCount + assistantCount + toolCount,
        userMessageCount: userCount,
        assistantMessageCount: assistantCount,
        toolMessageCount: toolCount,
        systemMessageCount: systemCount,
        summary: firstUserText.slice(0, 200) || undefined,
        filePath,
        sizeBytes: fileStat.size,
        agentRole: isSubagent ? 'subagent' : undefined,
        parentSessionId,
      };
```

- [ ] **Step 4: Add applyParentLink function**

Add to `src/core/db/session-repo.ts` after `upsertSession` (around line 201):

```typescript
import { validateParentLink, setParentSession } from './parent-link-repo.js';

export function applyParentLink(
  db: BetterSqlite3.Database,
  session: SessionInfo,
): void {
  if (!session.parentSessionId) return;

  // Don't overwrite manual decisions
  const existing = db.prepare('SELECT link_source FROM sessions WHERE id = ?')
    .get(session.id) as { link_source: string | null } | undefined;
  if (existing?.link_source === 'manual') return;

  const validation = validateParentLink(db, session.id, session.parentSessionId);
  if (validation === 'ok') {
    setParentSession(db, session.id, session.parentSessionId, 'path');
  }
  // If parent-not-found, silently skip — Pass 1 backfill will retry
}
```

Add facade method in `database.ts`:

```typescript
  applyParentLink(session: SessionInfo): void {
    sessions.applyParentLink(this.db, session);
  }
```

- [ ] **Step 5: Wire applyParentLink into the indexer**

In `src/core/indexer.ts`, find the `indexFile()` method where `db.upsertSession(info)` is called. Immediately after the upsert, add:

```typescript
    db.applyParentLink(info);
```

This ensures Layer 1 parent linking happens incrementally at index time for every new session, not just during backfill. If the parent isn't indexed yet (child-before-parent ordering), the call silently skips — Pass 1 backfill catches it on the next maintenance cycle.

- [ ] **Step 5: Run tests to verify they pass**

Run: `npm test -- tests/adapters/claude-code.test.ts`
Expected: ALL PASS

- [ ] **Step 6: Run full test suite**

Run: `npm test`
Expected: ALL PASS (804+ tests)

- [ ] **Step 7: Commit**

```bash
git add src/adapters/claude-code.ts src/adapters/types.ts src/core/db/session-repo.ts src/core/db/database.ts tests/adapters/claude-code.test.ts
git commit -m "feat: Layer 1 — extract parent session ID from subagent path"
```

---

### Task 5: Layer 2 — Content Heuristic Detection

**Files:**
- Create: `src/core/parent-detection.ts`
- Create: `tests/core/parent-detection.test.ts`

- [ ] **Step 1: Write failing tests for dispatch pattern detection and scoring**

Create `tests/core/parent-detection.test.ts`:

```typescript
import { describe, expect, it } from 'vitest';
import {
  isDispatchPattern,
  scoreCandidate,
  pickBestCandidate,
  DISPATCH_PATTERNS,
} from '../../src/core/parent-detection.js';

describe('parent-detection', () => {
  describe('isDispatchPattern', () => {
    it('detects <task> tag prefix', () => {
      expect(isDispatchPattern('<task> Review the code in /src')).toBe(true);
    });

    it('detects "Your task is to" prefix', () => {
      expect(isDispatchPattern('Your task is to analyze the following file')).toBe(true);
    });

    it('detects "You are a" agent pattern', () => {
      expect(isDispatchPattern('You are a code review agent. Review...')).toBe(true);
    });

    it('rejects normal user messages', () => {
      expect(isDispatchPattern('How do I fix this bug?')).toBe(false);
    });

    it('rejects empty/short messages', () => {
      expect(isDispatchPattern('')).toBe(false);
      expect(isDispatchPattern('hi')).toBe(false);
    });
  });

  describe('scoreCandidate', () => {
    const agentStart = '2026-04-13T10:05:00Z';

    it('scores higher for closer start times', () => {
      const close = scoreCandidate(agentStart, '2026-04-13T10:04:00Z', null, 'myproj', 'myproj');
      const far = scoreCandidate(agentStart, '2026-04-13T09:00:00Z', null, 'myproj', 'myproj');
      expect(close).toBeGreaterThan(far);
    });

    it('scores higher for matching project', () => {
      const match = scoreCandidate(agentStart, '2026-04-13T10:00:00Z', null, 'myproj', 'myproj');
      const noMatch = scoreCandidate(agentStart, '2026-04-13T10:00:00Z', null, 'myproj', 'other');
      expect(match).toBeGreaterThan(noMatch);
    });

    it('gives bonus for active (no end_time) parent', () => {
      const active = scoreCandidate(agentStart, '2026-04-13T10:00:00Z', null, 'myproj', 'myproj');
      const ended = scoreCandidate(agentStart, '2026-04-13T10:00:00Z', '2026-04-13T10:10:00Z', 'myproj', 'myproj');
      expect(active).toBeGreaterThan(ended);
    });

    it('returns 0 if agent started before parent', () => {
      const score = scoreCandidate(agentStart, '2026-04-13T11:00:00Z', null, 'myproj', 'myproj');
      expect(score).toBe(0);
    });

    it('returns 0 if agent started after parent ended', () => {
      const score = scoreCandidate(agentStart, '2026-04-13T09:00:00Z', '2026-04-13T10:00:00Z', 'myproj', 'myproj');
      expect(score).toBe(0);
    });
  });

  describe('pickBestCandidate', () => {
    it('returns null for empty list', () => {
      expect(pickBestCandidate([])).toBeNull();
    });

    it('returns the single candidate', () => {
      expect(pickBestCandidate([{ parentId: 'p1', score: 0.5 }])).toBe('p1');
    });

    it('returns best candidate when gap > 15%', () => {
      const result = pickBestCandidate([
        { parentId: 'p1', score: 0.8 },
        { parentId: 'p2', score: 0.3 },
      ]);
      expect(result).toBe('p1');
    });

    it('returns null when top 2 candidates within 15% (ambiguity rejection)', () => {
      const result = pickBestCandidate([
        { parentId: 'p1', score: 0.50 },
        { parentId: 'p2', score: 0.48 }, // 4% gap < 15% threshold
      ]);
      expect(result).toBeNull();
    });

    it('returns null when best score is 0', () => {
      expect(pickBestCandidate([{ parentId: 'p1', score: 0 }])).toBeNull();
    });
  });
});
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `npm test -- tests/core/parent-detection.test.ts`
Expected: FAIL — module doesn't exist.

- [ ] **Step 3: Implement parent-detection.ts**

Create `src/core/parent-detection.ts`:

```typescript
// src/core/parent-detection.ts — Layer 2: content heuristic + temporal scoring

export const DISPATCH_PATTERNS = [
  /^<task>/i,
  /^Your task is to\b/i,
  /^You are a\b.*\bagent\b/i,
  /^You are a\b.*\bassistant\b/i,
  /^<TASK>/,
  /^Review the (?:following|code|implementation)\b/i,
  /^Analyze (?:the |this )/i,
];

export function isDispatchPattern(firstMessage: string): boolean {
  if (!firstMessage || firstMessage.length < 10) return false;
  const trimmed = firstMessage.trimStart();
  return DISPATCH_PATTERNS.some((p) => p.test(trimmed));
}

/**
 * Score a candidate parent session. Returns 0 if temporal constraints fail.
 * Higher score = better match.
 *
 * Weights: time proximity 60%, project match 30%, active bonus 10%.
 */
export function scoreCandidate(
  agentStartTime: string,
  parentStartTime: string,
  parentEndTime: string | null,
  agentProject: string | null,
  parentProject: string | null,
): number {
  const agentStart = new Date(agentStartTime).getTime();
  const parentStart = new Date(parentStartTime).getTime();

  // Agent must have started after or at parent start
  if (agentStart < parentStart) return 0;

  // If parent has ended, agent must have started before parent end
  if (parentEndTime) {
    const parentEnd = new Date(parentEndTime).getTime();
    if (agentStart > parentEnd) return 0;
  }

  // Time proximity (60%): inverse of seconds between start times
  const diffSeconds = Math.abs(agentStart - parentStart) / 1000;
  const timeFactor = 1 / (1 + diffSeconds);
  const timeScore = timeFactor * 0.6;

  // Project match (30%)
  let projectScore = 0;
  if (agentProject && parentProject) {
    if (agentProject === parentProject) {
      projectScore = 1.0 * 0.3;
    }
    // Could add normalized cwd match at 0.7 * 0.3 here
  }

  // Active session bonus (10%)
  const activeScore = (parentEndTime == null ? 1.0 : 0.5) * 0.1;

  return timeScore + projectScore + activeScore;
}

/**
 * Given scored candidates, return the best match if unambiguous.
 * Returns null if top 2 candidates differ by < 15%.
 */
export function pickBestCandidate(
  scored: { parentId: string; score: number }[],
): string | null {
  if (scored.length === 0) return null;

  const sorted = [...scored].sort((a, b) => b.score - a.score);
  const best = sorted[0];

  if (best.score === 0) return null;

  // Ambiguity rejection: if top 2 are within 15%, refuse
  if (sorted.length >= 2) {
    const second = sorted[1];
    if (second.score > 0) {
      const gap = (best.score - second.score) / best.score;
      if (gap < 0.15) return null;
    }
  }

  return best.parentId;
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `npm test -- tests/core/parent-detection.test.ts`
Expected: ALL PASS

- [ ] **Step 5: Commit**

```bash
git add src/core/parent-detection.ts tests/core/parent-detection.test.ts
git commit -m "feat: Layer 2 — dispatch pattern detection + candidate scoring"
```

---

### Task 6: Layer 2 Backfill + Daemon Wiring

**Files:**
- Modify: `src/core/db/maintenance.ts`
- Modify: `src/daemon.ts:164-183`
- Test: `tests/core/db/parent-link-repo.test.ts` (add Layer 2 backfill tests)

- [ ] **Step 1: Write failing test for Layer 2 backfill**

Add to `tests/core/db/parent-link-repo.test.ts`:

```typescript
import { backfillSuggestedParents } from '../../../src/core/db/maintenance.js';

describe('backfillSuggestedParents', () => {
  it('suggests parent for gemini session with dispatch pattern', () => {
    // Parent claude-code session
    db.upsertSession({
      id: 'cc-parent', source: 'claude-code', startTime: '2026-04-13T10:00:00Z',
      cwd: '/test', project: 'myproj', messageCount: 20, userMessageCount: 10,
      assistantMessageCount: 10, toolMessageCount: 0, systemMessageCount: 0,
      filePath: '/test/cc.jsonl', sizeBytes: 100,
    });
    // Gemini agent session with dispatch pattern
    db.upsertSession({
      id: 'gem-agent', source: 'gemini-cli', startTime: '2026-04-13T10:05:00Z',
      cwd: '/test', project: 'myproj', messageCount: 5, userMessageCount: 2,
      assistantMessageCount: 3, toolMessageCount: 0, systemMessageCount: 0,
      filePath: '/test/gem.json', sizeBytes: 50,
      summary: '<task> Review the insight-hardening branch...',
    });

    const result = backfillSuggestedParents(db.raw);
    expect(result.suggested).toBeGreaterThanOrEqual(1);

    const row = db.raw.prepare('SELECT suggested_parent_id, link_checked_at FROM sessions WHERE id = ?')
      .get('gem-agent') as Record<string, unknown>;
    expect(row.suggested_parent_id).toBe('cc-parent');
    expect(row.link_checked_at).toBeTruthy();
  });

  it('marks link_checked_at even when no parent found', () => {
    db.upsertSession({
      id: 'gem-orphan', source: 'gemini-cli', startTime: '2026-04-13T10:05:00Z',
      cwd: '/test', project: 'myproj', messageCount: 5, userMessageCount: 2,
      assistantMessageCount: 3, toolMessageCount: 0, systemMessageCount: 0,
      filePath: '/test/gem-orphan.json', sizeBytes: 50,
      summary: '<task> Something with no parent...',
    });

    backfillSuggestedParents(db.raw);

    const row = db.raw.prepare('SELECT link_checked_at FROM sessions WHERE id = ?')
      .get('gem-orphan') as Record<string, unknown>;
    expect(row.link_checked_at).toBeTruthy();
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `npm test -- tests/core/db/parent-link-repo.test.ts`
Expected: FAIL — `backfillSuggestedParents` doesn't exist.

- [ ] **Step 3: Implement backfillSuggestedParents in maintenance.ts**

In `src/core/db/maintenance.ts`, add:

```typescript
import { isDispatchPattern, scoreCandidate, pickBestCandidate } from '../parent-detection.js';
import { setSuggestedParent } from './parent-link-repo.js';

export function backfillSuggestedParents(
  db: BetterSqlite3.Database,
): { checked: number; suggested: number } {
  let checked = 0;
  let suggested = 0;

  // Find unchecked gemini/codex sessions
  const candidates = db.prepare(`
    SELECT id, start_time, project, cwd, summary FROM sessions
    WHERE parent_session_id IS NULL
      AND suggested_parent_id IS NULL
      AND link_checked_at IS NULL
      AND link_source IS NULL
      AND source IN ('gemini-cli', 'codex')
    LIMIT 500
  `).all() as {
    id: string;
    start_time: string;
    project: string | null;
    cwd: string;
    summary: string | null;
  }[];

  const markChecked = db.prepare(`
    UPDATE sessions SET link_checked_at = datetime('now') WHERE id = ?
  `);

  for (const candidate of candidates) {
    checked++;

    // Check if first message matches dispatch pattern (summary = first user message truncated)
    if (!candidate.summary || !isDispatchPattern(candidate.summary)) {
      markChecked.run(candidate.id);
      continue;
    }

    // Find candidate parents: claude-code sessions overlapping in time
    const parents = db.prepare(`
      SELECT id, start_time, end_time, project FROM sessions
      WHERE source IN ('claude-code', 'claude')
        AND start_time <= ?
        AND (end_time IS NULL OR end_time >= ?)
        AND parent_session_id IS NULL
        AND hidden_at IS NULL
    `).all(candidate.start_time, candidate.start_time) as {
      id: string;
      start_time: string;
      end_time: string | null;
      project: string | null;
    }[];

    const scored = parents.map((p) => ({
      parentId: p.id,
      score: scoreCandidate(
        candidate.start_time,
        p.start_time,
        p.end_time,
        candidate.project,
        p.project,
      ),
    }));

    const bestParent = pickBestCandidate(scored);
    if (bestParent) {
      setSuggestedParent(db, candidate.id, bestParent);
      suggested++;
    } else {
      markChecked.run(candidate.id);
    }
  }

  return { checked, suggested };
}
```

- [ ] **Step 4: Wire backfill into daemon startup**

In `src/daemon.ts`, after the existing DB maintenance block (around line 183), add:

```typescript
    // Backfill parent session links
    try {
      const parentLinks = db.backfillParentLinks();
      if (parentLinks.linked > 0 || parentLinks.tierUpgraded > 0) {
        emit({
          event: 'backfill',
          type: 'parent_links',
          linked: parentLinks.linked,
          tierUpgraded: parentLinks.tierUpgraded,
        });
      }
      const suggestions = db.backfillSuggestedParents();
      if (suggestions.suggested > 0) {
        emit({
          event: 'backfill',
          type: 'suggested_parents',
          checked: suggestions.checked,
          suggested: suggestions.suggested,
        });
      }
    } catch (err) {
      log.warn('parent link backfill failed', {}, err);
    }
```

Add facade method in `database.ts`:

```typescript
  backfillSuggestedParents() {
    return maint.backfillSuggestedParents(this.db);
  }
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `npm test -- tests/core/db/parent-link-repo.test.ts`
Expected: ALL PASS

- [ ] **Step 6: Run full test suite**

Run: `npm test`
Expected: ALL PASS

- [ ] **Step 7: Commit**

```bash
git add src/core/db/maintenance.ts src/core/db/database.ts src/daemon.ts tests/core/db/parent-link-repo.test.ts
git commit -m "feat: Layer 2 heuristic backfill + daemon startup wiring"
```

---

### Task 7: HTTP API Endpoints for Manual Override

**Files:**
- Modify: `src/web.ts`
- Create: `tests/web/parent-link-api.test.ts`

- [ ] **Step 1: Write failing tests for all 4 endpoints**

Create `tests/web/parent-link-api.test.ts`:

```typescript
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { Database } from '../../src/core/db/database.js';
import { createApp } from '../../src/web.js';

describe('parent link API', () => {
  let db: Database;
  let app: ReturnType<typeof createApp>;
  let tmpDir: string;

  beforeEach(() => {
    tmpDir = mkdtempSync(join(tmpdir(), 'parent-api-test-'));
    db = new Database(join(tmpDir, 'test.sqlite'));
    app = createApp(db);

    // Insert test sessions
    db.upsertSession({
      id: 'parent-1', source: 'claude-code', startTime: '2026-04-13T10:00:00Z',
      cwd: '/test', messageCount: 10, userMessageCount: 5, assistantMessageCount: 5,
      toolMessageCount: 0, systemMessageCount: 0, filePath: '/test/p.jsonl', sizeBytes: 100,
    });
    db.upsertSession({
      id: 'child-1', source: 'gemini-cli', startTime: '2026-04-13T10:05:00Z',
      cwd: '/test', messageCount: 5, userMessageCount: 2, assistantMessageCount: 3,
      toolMessageCount: 0, systemMessageCount: 0, filePath: '/test/c.jsonl', sizeBytes: 50,
    });
  });

  afterEach(() => {
    db.close();
    rmSync(tmpDir, { recursive: true });
  });

  describe('POST /api/sessions/:id/link', () => {
    it('links child to parent', async () => {
      const res = await app.request('/api/sessions/child-1/link', {
        method: 'POST',
        body: JSON.stringify({ parentId: 'parent-1' }),
        headers: { 'Content-Type': 'application/json' },
      });
      expect(res.status).toBe(200);
      const body = await res.json();
      expect(body.ok).toBe(true);
    });

    it('rejects self-link', async () => {
      const res = await app.request('/api/sessions/parent-1/link', {
        method: 'POST',
        body: JSON.stringify({ parentId: 'parent-1' }),
        headers: { 'Content-Type': 'application/json' },
      });
      expect(res.status).toBe(400);
    });

    it('rejects non-existent parent', async () => {
      const res = await app.request('/api/sessions/child-1/link', {
        method: 'POST',
        body: JSON.stringify({ parentId: 'nonexistent' }),
        headers: { 'Content-Type': 'application/json' },
      });
      expect(res.status).toBe(400);
    });
  });

  describe('DELETE /api/sessions/:id/link', () => {
    it('unlinks child from parent', async () => {
      db.setParentSession('child-1', 'parent-1', 'path');
      const res = await app.request('/api/sessions/child-1/link', {
        method: 'DELETE',
      });
      expect(res.status).toBe(200);
    });
  });

  describe('POST /api/sessions/:id/confirm-suggestion', () => {
    it('promotes suggestion to confirmed link', async () => {
      db.setSuggestedParent('child-1', 'parent-1');
      const res = await app.request('/api/sessions/child-1/confirm-suggestion', {
        method: 'POST',
      });
      expect(res.status).toBe(200);
      const body = await res.json();
      expect(body.ok).toBe(true);
    });

    it('returns error if no suggestion exists', async () => {
      const res = await app.request('/api/sessions/child-1/confirm-suggestion', {
        method: 'POST',
      });
      expect(res.status).toBe(400);
    });
  });

  describe('DELETE /api/sessions/:id/suggestion', () => {
    it('dismisses suggestion with correct expected value', async () => {
      db.setSuggestedParent('child-1', 'parent-1');
      const res = await app.request('/api/sessions/child-1/suggestion', {
        method: 'DELETE',
        body: JSON.stringify({ suggestedParentId: 'parent-1' }),
        headers: { 'Content-Type': 'application/json' },
      });
      expect(res.status).toBe(200);
    });

    it('rejects stale expected value', async () => {
      db.setSuggestedParent('child-1', 'parent-1');
      const res = await app.request('/api/sessions/child-1/suggestion', {
        method: 'DELETE',
        body: JSON.stringify({ suggestedParentId: 'wrong-id' }),
        headers: { 'Content-Type': 'application/json' },
      });
      expect(res.status).toBe(409);
    });
  });

  describe('GET /api/sessions/:id/children', () => {
    it('returns confirmed + suggested children', async () => {
      db.setParentSession('child-1', 'parent-1', 'manual');
      const res = await app.request('/api/sessions/parent-1/children');
      expect(res.status).toBe(200);
      const body = await res.json();
      expect(body.confirmed).toHaveLength(1);
      expect(body.confirmed[0].id).toBe('child-1');
    });
  });
});
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `npm test -- tests/web/parent-link-api.test.ts`
Expected: FAIL — endpoints don't exist.

- [ ] **Step 3: Add endpoints to web.ts**

In `src/web.ts`, after the existing session endpoints (around line 393), add:

```typescript
  // --- Parent link management ---

  app.post('/api/sessions/:id/link', async (c) => {
    const sessionId = c.req.param('id');
    const body = await c.req.json<{ parentId: string }>();
    if (!body?.parentId) return c.json({ error: 'parentId required' }, 400);

    const validation = db.validateParentLink(sessionId, body.parentId);
    if (validation !== 'ok') return c.json({ error: validation }, 400);

    db.setParentSession(sessionId, body.parentId, 'manual');
    return c.json({ ok: true });
  });

  app.delete('/api/sessions/:id/link', (c) => {
    const sessionId = c.req.param('id');
    db.clearParentSession(sessionId);
    return c.json({ ok: true });
  });

  app.post('/api/sessions/:id/confirm-suggestion', (c) => {
    const sessionId = c.req.param('id');
    const result = db.confirmSuggestion(sessionId);
    if (!result.ok) return c.json({ error: result.error }, 400);
    return c.json({ ok: true });
  });

  app.delete('/api/sessions/:id/suggestion', async (c) => {
    const sessionId = c.req.param('id');
    const body = await c.req.json<{ suggestedParentId: string }>();
    if (!body?.suggestedParentId) return c.json({ error: 'suggestedParentId required' }, 400);

    const cleared = db.clearSuggestedParent(sessionId, body.suggestedParentId);
    if (!cleared) return c.json({ error: 'stale-suggestion' }, 409);
    return c.json({ ok: true });
  });

  app.get('/api/sessions/:id/children', (c) => {
    const parentId = c.req.param('id');
    const limitParam = c.req.query('limit');
    const offsetParam = c.req.query('offset');
    const limit = Math.min(limitParam ? parseInt(limitParam, 10) : 20, 100);
    const offset = offsetParam ? parseInt(offsetParam, 10) : 0;

    const confirmed = db.childSessions(parentId, limit, offset);
    const suggested = db.suggestedChildSessions(parentId);
    return c.json({ confirmed, suggested });
  });
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `npm test -- tests/web/parent-link-api.test.ts`
Expected: ALL PASS

- [ ] **Step 5: Run full test suite**

Run: `npm test`
Expected: ALL PASS

- [ ] **Step 6: Commit**

```bash
git add src/web.ts tests/web/parent-link-api.test.ts
git commit -m "feat: HTTP API endpoints for parent link management"
```

---

### Task 8: Swift Model + Database Read Methods

**Files:**
- Modify: `macos/Engram/Models/Session.swift`
- Modify: `macos/Engram/Core/Database.swift`

- [ ] **Step 1: Add new fields to Session model**

In `macos/Engram/Models/Session.swift`, add properties after `generatedTitle`:

```swift
    let parentSessionId: String?
    let suggestedParentId: String?
    let linkSource: String?
```

Add CodingKeys after `generatedTitle`:

```swift
        case parentSessionId = "parent_session_id"
        case suggestedParentId = "suggested_parent_id"
        case linkSource = "link_source"
```

Add computed property:

```swift
    var hasParent: Bool { parentSessionId != nil }
    var hasSuggestedParent: Bool { suggestedParentId != nil && parentSessionId == nil }
```

- [ ] **Step 2: Update recentSessions query in Database.swift**

In `macos/Engram/Core/Database.swift`, modify `recentSessions()`:

```swift
    nonisolated func recentSessions(limit: Int = 8) throws -> [Session] {
        try readInBackground { db in
            try Session.fetchAll(db, sql: """
                SELECT * FROM sessions
                WHERE hidden_at IS NULL
                  AND parent_session_id IS NULL
                  AND (tier IS NULL OR tier != 'skip')
                ORDER BY start_time DESC LIMIT ?
            """, arguments: [limit])
        }
    }
```

- [ ] **Step 3: Add child query methods to DatabaseManager**

In `macos/Engram/Core/Database.swift`, add:

```swift
    nonisolated func childSessions(parentId: String, limit: Int = 20, offset: Int = 0) throws -> [Session] {
        try readInBackground { db in
            try Session.fetchAll(db, sql: """
                SELECT * FROM sessions
                WHERE parent_session_id = ? AND hidden_at IS NULL
                ORDER BY start_time ASC
                LIMIT ? OFFSET ?
            """, arguments: [parentId, limit, offset])
        }
    }

    nonisolated func suggestedChildSessions(parentId: String) throws -> [Session] {
        try readInBackground { db in
            try Session.fetchAll(db, sql: """
                SELECT * FROM sessions
                WHERE suggested_parent_id = ?
                  AND parent_session_id IS NULL
                  AND hidden_at IS NULL
                ORDER BY start_time ASC
            """, arguments: [parentId])
        }
    }

    nonisolated func childCount(parentIds: [String]) throws -> [String: Int] {
        guard !parentIds.isEmpty else { return [:] }
        try readInBackground { db in
            let placeholders = parentIds.map { _ in "?" }.joined(separator: ",")
            let rows = try Row.fetchAll(db, sql: """
                SELECT parent_session_id, COUNT(*) as cnt
                FROM sessions
                WHERE parent_session_id IN (\(placeholders)) AND hidden_at IS NULL
                GROUP BY parent_session_id
            """, arguments: StatementArguments(parentIds))
            var result: [String: Int] = [:]
            for row in rows {
                let pid: String = row["parent_session_id"]
                let cnt: Int = row["cnt"]
                result[pid] = cnt
            }
            return result
        }
    }

    nonisolated func suggestedChildCount(parentIds: [String]) throws -> [String: Int] {
        guard !parentIds.isEmpty else { return [:] }
        try readInBackground { db in
            let placeholders = parentIds.map { _ in "?" }.joined(separator: ",")
            let rows = try Row.fetchAll(db, sql: """
                SELECT suggested_parent_id, COUNT(*) as cnt
                FROM sessions
                WHERE suggested_parent_id IN (\(placeholders))
                  AND parent_session_id IS NULL AND hidden_at IS NULL
                GROUP BY suggested_parent_id
            """, arguments: StatementArguments(parentIds))
            var result: [String: Int] = [:]
            for row in rows {
                let pid: String = row["suggested_parent_id"]
                let cnt: Int = row["cnt"]
                result[pid] = cnt
            }
            return result
        }
    }

    nonisolated func getSession(id: String) throws -> Session? {
        try readInBackground { db in
            try Session.fetchOne(db, sql: "SELECT * FROM sessions WHERE id = ?", arguments: [id])
        }
    }
```

- [ ] **Step 4: Add topLevelOnly parameter to listSessions (do NOT change default)**

In `macos/Engram/Core/Database.swift`, add a new parameter to `listSessions()`:

```swift
    nonisolated func listSessions(
        sources: [String]? = nil,
        projects: [String]? = nil,
        since: String? = nil,
        subAgent: Bool? = nil,
        topLevelOnly: Bool = false,  // NEW — only HomeView and SessionListView pass true
        sort: [KeyPathComparator<Session>]? = nil,
        limit: Int = 2000,
        offset: Int = 0
    ) throws -> [Session] {
```

Inside the method, add the filter conditionally:

```swift
        if topLevelOnly {
            conditions.append("parent_session_id IS NULL")
        }
```

**IMPORTANT:** Do NOT change the default behavior of `listSessions()`. Stats, timeline, activity, and other views must continue seeing all sessions (including children). Only HomeView and SessionListView pass `topLevelOnly: true` at their call sites.

- [ ] **Step 5: Build to verify compilation**

Run: `cd macos && xcodegen generate && xcodebuild -project Engram.xcodeproj -scheme Engram -configuration Debug build`
Expected: BUILD SUCCEEDED

- [ ] **Step 6: Commit**

```bash
git add macos/Engram/Models/Session.swift macos/Engram/Core/Database.swift
git commit -m "feat: Swift model + DB read methods for parent session grouping"
```

---

### Task 9: Swift DaemonClient — Link Management API

**Files:**
- Modify: `macos/Engram/Core/DaemonClient.swift`

- [ ] **Step 1: Add link management methods**

In `macos/Engram/Core/DaemonClient.swift`, add response types and methods:

```swift
    struct LinkResponse: Decodable {
        let ok: Bool
        let error: String?
    }

    func linkSession(sessionId: String, parentId: String) async throws -> LinkResponse {
        struct Body: Encodable { let parentId: String }
        return try await post("/api/sessions/\(sessionId)/link", body: Body(parentId: parentId))
    }

    func unlinkSession(sessionId: String) async throws {
        try await delete("/api/sessions/\(sessionId)/link")
    }

    func confirmSuggestion(sessionId: String) async throws -> LinkResponse {
        return try await post("/api/sessions/\(sessionId)/confirm-suggestion")
    }

    func dismissSuggestion(sessionId: String, suggestedParentId: String) async throws {
        struct Body: Encodable { let suggestedParentId: String }
        let request = try buildRequest("/api/sessions/\(sessionId)/suggestion", method: "DELETE", body: Body(suggestedParentId: suggestedParentId))
        let (_, response) = try await session.data(for: request)
        try validateResponse(response)
    }
```

- [ ] **Step 2: Build to verify compilation**

Run: `cd macos && xcodebuild -project Engram.xcodeproj -scheme Engram -configuration Debug build`
Expected: BUILD SUCCEEDED

- [ ] **Step 3: Commit**

```bash
git add macos/Engram/Core/DaemonClient.swift
git commit -m "feat: DaemonClient methods for parent link management"
```

---

### Task 10: ExpandableSessionCard Component

**Files:**
- Create: `macos/Engram/Components/ExpandableSessionCard.swift`

- [ ] **Step 1: Create the expandable card component**

Create `macos/Engram/Components/ExpandableSessionCard.swift`:

```swift
import SwiftUI

struct ExpandableSessionCard: View {
    let session: Session
    let confirmedChildCount: Int
    let suggestedChildCount: Int
    var onTap: (() -> Void)? = nil
    var onChildTap: ((Session) -> Void)? = nil
    var onConfirmSuggestion: ((Session) -> Void)? = nil
    var onDismissSuggestion: ((Session) -> Void)? = nil

    @State private var isExpanded = false
    @State private var children: [Session] = []
    @State private var suggestedChildren: [Session] = []
    @State private var isLoadingChildren = false
    @Environment(DatabaseManager.self) var db

    private var totalChildCount: Int { confirmedChildCount + suggestedChildCount }
    private var hasChildren: Bool { totalChildCount > 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Parent card row
            HStack(spacing: 6) {
                // Disclosure triangle
                if hasChildren {
                    Button(action: { withAnimation(.easeInOut(duration: 0.15)) { toggleExpand() } }) {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.caption2)
                            .foregroundStyle(suggestedChildCount > 0 && confirmedChildCount == 0
                                ? Theme.tertiaryText : Theme.secondaryText)
                            .frame(width: 12)
                    }
                    .buttonStyle(.plain)
                } else {
                    Spacer().frame(width: 12)
                }

                // Reuse SessionCard layout
                SessionCard(session: session, onTap: onTap)
            }
            .overlay(alignment: .trailing) {
                if hasChildren {
                    childBadge
                        .padding(.trailing, 90) // offset before msg count + time + chevron
                }
            }

            // Expanded children
            if isExpanded {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(children, id: \.id) { child in
                        CompactChildRow(session: child, isConfirmed: true, onTap: { onChildTap?(child) })
                    }
                    ForEach(suggestedChildren, id: \.id) { child in
                        CompactChildRow(
                            session: child,
                            isConfirmed: false,
                            onTap: { onChildTap?(child) },
                            onConfirm: { onConfirmSuggestion?(child) },
                            onDismiss: { onDismissSuggestion?(child) }
                        )
                    }
                    if confirmedChildCount > children.count {
                        Button("show \(confirmedChildCount - children.count) more...") {
                            loadMoreChildren()
                        }
                        .font(.caption)
                        .foregroundStyle(Theme.accentColor)
                        .padding(.leading, 44)
                        .padding(.vertical, 4)
                        .buttonStyle(.plain)
                    }
                }
                .padding(.leading, 18)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private var childBadge: some View {
        Group {
            if confirmedChildCount > 0 {
                Text("\(totalChildCount) agents")
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Theme.accentColor.opacity(0.12))
                    .foregroundStyle(Theme.accentColor)
                    .clipShape(Capsule())
            } else {
                Text("~\(suggestedChildCount) suggested")
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Theme.tertiaryText.opacity(0.1))
                    .foregroundStyle(Theme.tertiaryText)
                    .clipShape(Capsule())
            }
        }
    }

    private func toggleExpand() {
        isExpanded.toggle()
        if isExpanded && children.isEmpty && suggestedChildren.isEmpty {
            loadChildren()
        }
    }

    private func loadChildren() {
        isLoadingChildren = true
        Task.detached {
            let confirmed = try? db.childSessions(parentId: session.id, limit: 20)
            let suggested = try? db.suggestedChildSessions(parentId: session.id)
            await MainActor.run {
                children = confirmed ?? []
                suggestedChildren = suggested ?? []
                isLoadingChildren = false
            }
        }
    }

    private func loadMoreChildren() {
        let offset = children.count
        Task.detached {
            let more = try? db.childSessions(parentId: session.id, limit: 20, offset: offset)
            await MainActor.run {
                children.append(contentsOf: more ?? [])
            }
        }
    }

    // Reset cached children when parent view reloads data (e.g. after confirm/dismiss)
    private func resetIfCountsChanged() {
        children = []
        suggestedChildren = []
        if isExpanded { loadChildren() }
    }
}
```

**IMPORTANT:** The parent view (HomeView/SessionListView) reloads data after confirm/dismiss, causing `confirmedChildCount` and `suggestedChildCount` to change. But the card's internal `@State` (children, suggestedChildren) won't update automatically. Add this modifier on the `ExpandableSessionCard` in the parent ForEach:

```swift
    .onChange(of: confirmedChildCount + suggestedChildCount) { resetIfCountsChanged() }
```

Alternatively, make `resetIfCountsChanged()` an instance method and call it via `.onChange`. The key point: **stale @State after parent reload is a real bug — the card must invalidate its cached children when counts change.**

```swift (continued from above)

struct CompactChildRow: View {
    let session: Session
    let isConfirmed: Bool
    var onTap: (() -> Void)? = nil
    var onConfirm: (() -> Void)? = nil
    var onDismiss: (() -> Void)? = nil

    var body: some View {
        // NOTE: Do NOT nest Buttons inside a Button — SwiftUI swallows inner tap events.
        // Use HStack with onTapGesture on the row, and separate Buttons for actions.
        HStack(spacing: 8) {
            SourcePill(source: session.source)
                .scaleEffect(0.85)

            Text(session.displayTitle)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(isConfirmed ? Theme.primaryText : Theme.tertiaryText)

            Spacer()

            if !isConfirmed {
                Button("Confirm") { onConfirm?() }
                    .font(.caption2)
                    .foregroundStyle(Theme.accentColor)
                    .buttonStyle(.plain)
                Button("×") { onDismiss?() }
                    .font(.caption)
                    .foregroundStyle(Theme.tertiaryText)
                    .buttonStyle(.plain)
            }

            Text(SessionCard.relativeTime(session.startTime))
                .font(.caption2)
                .foregroundStyle(Theme.tertiaryText)
                .frame(width: 36, alignment: .trailing)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(isConfirmed ? Color.clear : Theme.surface.opacity(0.5))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(isConfirmed ? Color.clear : Theme.border.opacity(0.5), lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle()) // make entire row tappable
        .onTapGesture { onTap?() }
    }
}
```

- [ ] **Step 2: Run xcodegen and build**

Run: `cd macos && xcodegen generate && xcodebuild -project Engram.xcodeproj -scheme Engram -configuration Debug build`
Expected: BUILD SUCCEEDED

- [ ] **Step 3: Commit**

```bash
git add macos/Engram/Components/ExpandableSessionCard.swift macos/project.yml
git commit -m "feat: ExpandableSessionCard + CompactChildRow components"
```

---

### Task 11: HomeView — Expandable Session Grouping

**Files:**
- Modify: `macos/Engram/Views/Pages/HomeView.swift`

- [ ] **Step 1: Add child count state and loading**

In `HomeView.swift`, add state properties:

```swift
    @State private var confirmedCounts: [String: Int] = [:]
    @State private var suggestedCounts: [String: Int] = [:]
```

In `loadData()`, replace the `Task.detached` block to include child counts. The full updated block:

```swift
        let data = try await Task.detached {
            let kpi = try db.kpiStats()
            let daily = try db.dailyActivity(days: 30)
            let hourly = try db.hourlyActivity()
            let source = try db.sourceDistribution()
            let tiers = try db.tierDistribution()
            let recent = try db.recentSessions(limit: 8)
            // Load child counts for recent sessions
            let parentIds = recent.map(\.id)
            let confirmed = try db.childCount(parentIds: parentIds)
            let suggested = try db.suggestedChildCount(parentIds: parentIds)
            return (kpi, daily, hourly, source, tiers, recent, confirmed, suggested)
        }.value
        kpi = data.0
        dailyActivity = data.1
        hourlyActivity = data.2
        sourceDist = data.3
        tiers = data.4
        recentSessions = data.5
        confirmedCounts = data.6
        suggestedCounts = data.7
```

- [ ] **Step 2: Replace SessionCard with ExpandableSessionCard in recentSessionsSection**

Replace the ForEach body in `recentSessionsSection`:

```swift
            ForEach(Array(recentSessions.enumerated()), id: \.element.id) { index, session in
                ExpandableSessionCard(
                    session: session,
                    confirmedChildCount: confirmedCounts[session.id] ?? 0,
                    suggestedChildCount: suggestedCounts[session.id] ?? 0,
                    onTap: {
                        NotificationCenter.default.post(
                            name: .openSession,
                            object: SessionBox(session)
                        )
                    },
                    onChildTap: { child in
                        NotificationCenter.default.post(
                            name: .openSession,
                            object: SessionBox(child)
                        )
                    },
                    onConfirmSuggestion: { child in
                        Task {
                            try? await daemonClient.confirmSuggestion(sessionId: child.id)
                            await loadData()
                        }
                    },
                    onDismissSuggestion: { child in
                        Task {
                            if let suggestedId = child.suggestedParentId {
                                try? await daemonClient.dismissSuggestion(
                                    sessionId: child.id,
                                    suggestedParentId: suggestedId
                                )
                            }
                            await loadData()
                        }
                    }
                )
                .accessibilityIdentifier("home_recentSession_\(index)")
            }
```

Add `@Environment(DaemonClient.self) var daemonClient` at the top of the view.

- [ ] **Step 3: Build and test in browser**

Run: `cd macos && xcodebuild -project Engram.xcodeproj -scheme Engram -configuration Debug build`
Expected: BUILD SUCCEEDED. Launch app, verify Home page shows expandable cards for sessions with children.

- [ ] **Step 4: Commit**

```bash
git add macos/Engram/Views/Pages/HomeView.swift
git commit -m "feat: HomeView expandable session grouping with child counts"
```

---

### Task 12: SessionListView — Grouped List + Agent Filter

**Files:**
- Modify: `macos/Engram/Views/SessionListView.swift`

- [ ] **Step 1: Add child count state and loading**

Add state properties to `SessionListView`:

```swift
    @State private var confirmedCounts: [String: Int] = [:]
    @State private var suggestedCounts: [String: Int] = [:]
```

In `loadSessions()`, after loading sessions, add child count loading:

```swift
        let parentIds = sessions.map(\.id)
        confirmedCounts = (try? db.childCount(parentIds: parentIds)) ?? [:]
        suggestedCounts = (try? db.suggestedChildCount(parentIds: parentIds)) ?? [:]
```

- [ ] **Step 2: Update session rendering based on agent filter mode**

In the session list rendering, replace `SessionCard` with conditional rendering:

```swift
// In the ForEach for session list
if agentFilterMode == 2 {
    // Hide mode: plain cards, no triangle/badge
    SessionCard(session: session, onTap: { selectSession(session) })
} else if agentFilterMode == 1 {
    // Agents only: flat list, plain cards
    SessionCard(session: session, onTap: { selectSession(session) })
} else {
    // All: expandable grouped view
    ExpandableSessionCard(
        session: session,
        confirmedChildCount: confirmedCounts[session.id] ?? 0,
        suggestedChildCount: suggestedCounts[session.id] ?? 0,
        onTap: { selectSession(session) },
        onChildTap: { child in selectSession(child) },
        onConfirmSuggestion: { child in confirmSuggestion(child) },
        onDismissSuggestion: { child in dismissSuggestion(child) }
    )
}
```

Add helper methods:

```swift
    private func confirmSuggestion(_ child: Session) {
        Task {
            try? await daemonClient.confirmSuggestion(sessionId: child.id)
            await loadSessions()
        }
    }

    private func dismissSuggestion(_ child: Session) {
        Task {
            if let suggestedId = child.suggestedParentId {
                try? await daemonClient.dismissSuggestion(sessionId: child.id, suggestedParentId: suggestedId)
            }
            await loadSessions()
        }
    }
```

Add `@Environment(DaemonClient.self) var daemonClient` at the top.

- [ ] **Step 3: Build and test**

Run: `cd macos && xcodebuild -project Engram.xcodeproj -scheme Engram -configuration Debug build`
Expected: BUILD SUCCEEDED. Launch app, verify Sessions page shows grouped expandable cards in "All" mode, flat agent list in "Agents" mode, no triangle/badge in "Hide" mode.

- [ ] **Step 4: Commit**

```bash
git add macos/Engram/Views/SessionListView.swift
git commit -m "feat: SessionListView grouped list with agent filter interaction"
```

---

### Task 13: SessionDetailView — Breadcrumbs + Child List

**Files:**
- Modify: `macos/Engram/Views/SessionDetailView.swift`

- [ ] **Step 1: Add parent breadcrumb at top of detail view**

In `SessionDetailView.swift`, add state — **use separate vars for confirmed vs suggested parent** to avoid mixing their UI:

```swift
    @State private var confirmedParent: Session?   // from parent_session_id
    @State private var suggestedParent: Session?   // from suggested_parent_id (only when no confirmed parent)
    @State private var childrenSessions: [Session] = []
```

After the toolbar section, before the transcript, add:

```swift
    // Confirmed parent breadcrumb
    if let parent = confirmedParent {
        Button(action: { navigateToSession(parent) }) {
            HStack(spacing: 4) {
                Image(systemName: "arrow.left")
                    .font(.caption2)
                Text("Parent: \(parent.displayTitle)")
                    .font(.caption)
                    .lineLimit(1)
            }
            .foregroundStyle(Theme.accentColor)
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
        }
        .buttonStyle(.plain)
    }

    // Suggested parent breadcrumb (only shown when no confirmed parent)
    if confirmedParent == nil, let suggested = suggestedParent {
        HStack(spacing: 8) {
            Text("← Suggested parent: \(suggested.displayTitle)")
                .font(.caption)
                .lineLimit(1)
                .foregroundStyle(Theme.tertiaryText)

            Button("Confirm") {
                Task {
                    try? await daemonClient.confirmSuggestion(sessionId: session.id)
                    loadParentInfo()
                }
            }
            .font(.caption2)
            .foregroundStyle(Theme.accentColor)
            .buttonStyle(.plain)

            Button("Dismiss") {
                Task {
                    if let suggestedId = session.suggestedParentId {
                        try? await daemonClient.dismissSuggestion(sessionId: session.id, suggestedParentId: suggestedId)
                    }
                    loadParentInfo()  // refresh UI after dismiss
                }
            }
            .font(.caption2)
            .foregroundStyle(Theme.tertiaryText)
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }
```

- [ ] **Step 2: Add child session list at bottom**

After the transcript section, add:

```swift
    // Child sessions
    if !childrenSessions.isEmpty {
        Divider().padding(.horizontal, 16)
        VStack(alignment: .leading, spacing: 4) {
            Text("Agent Sessions (\(childrenSessions.count))")
                .font(.caption)
                .foregroundStyle(Theme.secondaryText)
                .padding(.horizontal, 16)

            ForEach(childrenSessions, id: \.id) { child in
                CompactChildRow(session: child, isConfirmed: true) {
                    navigateToSession(child)
                }
                .padding(.horizontal, 12)
            }
        }
        .padding(.vertical, 8)
    }
```

- [ ] **Step 3: Load parent and children info**

Add loading methods:

```swift
    private func loadParentInfo() {
        Task.detached {
            // Re-fetch session from DB to get latest state (Session is a value type)
            let freshSession = try? db.getSession(id: session.id)

            var confirmed: Session?
            var suggested: Session?
            if let pid = (freshSession ?? session).parentSessionId {
                confirmed = try? db.getSession(id: pid)
            } else if let spid = (freshSession ?? session).suggestedParentId {
                suggested = try? db.getSession(id: spid)
            }
            let children = try? db.childSessions(parentId: session.id)
            await MainActor.run {
                confirmedParent = confirmed
                suggestedParent = suggested
                childrenSessions = children ?? []
            }
        }
    }

    private func navigateToSession(_ session: Session) {
        NotificationCenter.default.post(name: .openSession, object: SessionBox(session))
    }
```

Add `.task(id: session.id) { loadParentInfo() }` to the view body.

- [ ] **Step 4: Build and test**

Run: `cd macos && xcodebuild -project Engram.xcodeproj -scheme Engram -configuration Debug build`
Expected: BUILD SUCCEEDED. Launch app, verify detail view shows parent breadcrumb for child sessions and child list for parent sessions.

- [ ] **Step 5: Commit**

```bash
git add macos/Engram/Views/SessionDetailView.swift
git commit -m "feat: SessionDetailView breadcrumbs + child session list"
```

---

### Task 14: Build, Lint, Full Test Suite

**Files:** None new — verification only

- [ ] **Step 1: Run TypeScript linter**

Run: `npm run lint`
Expected: No errors (biome check passes)

- [ ] **Step 2: Run full TypeScript test suite**

Run: `npm test`
Expected: ALL PASS (should be 804+ tests plus new ones ~830+)

- [ ] **Step 3: Build TypeScript**

Run: `npm run build`
Expected: Clean compile, no errors

- [ ] **Step 4: Build macOS app**

Run: `cd macos && xcodegen generate && xcodebuild -project Engram.xcodeproj -scheme Engram -configuration Debug build`
Expected: BUILD SUCCEEDED

- [ ] **Step 5: Run dead code detection**

Run: `npm run knip`
Expected: No unexpected dead code from new modules

- [ ] **Step 6: Commit any lint fixes**

```bash
git add -A
git commit -m "chore: lint fixes for agent session grouping"
```

---

## Dependency Graph

```
Task 1 (schema) → Task 2 (repo) → Task 3 (facade+backfill)
                                  → Task 4 (Layer 1 adapter)
                                  → Task 5 (Layer 2 detection)
                   Task 3 ────────→ Task 6 (Layer 2 backfill+daemon)
                                  → Task 7 (HTTP API)
Task 1 ──────────→ Task 8 (Swift model+DB) → Task 9 (DaemonClient)
                                            → Task 10 (ExpandableCard)
                   Task 9+10 ──────────────→ Task 11 (HomeView)
                                            → Task 12 (SessionListView)
                                            → Task 13 (SessionDetailView)
All ───────────────────────────────────────→ Task 14 (verification)
```

**Parallelizable:**
- Tasks 4, 5, 6, 7 can run in parallel (after Task 3)
- Tasks 8, 9, 10 can run in parallel (after Task 1)
- Tasks 11, 12, 13 can run in parallel (after Tasks 9+10)
