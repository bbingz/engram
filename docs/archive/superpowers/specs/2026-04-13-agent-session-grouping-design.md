# Agent Session Grouping & Collapsing

**Date:** 2026-04-13
**Status:** Approved
**Problem:** Agent sessions dispatched by Claude Code to Gemini/Codex clutter the home timeline. They appear as independent sessions because their respective adapters don't recognize them as sub-agents.

## 1. Data Model

### New columns on `sessions` table

```sql
parent_session_id TEXT REFERENCES sessions(id) ON DELETE SET NULL
suggested_parent_id TEXT    -- Layer 2 heuristic suggestion, not confirmed
link_source TEXT            -- 'path' | 'manual' | NULL
link_checked_at TEXT        -- ISO8601, prevents repeated backfill scans
```

- `parent_session_id`: confirmed parent link. NULL = top-level session.
- `suggested_parent_id`: Layer 2 heuristic match, displayed as weak/dashed association in UI. User confirmation promotes to `parent_session_id`.
- `link_source`: provenance of confirmed link. `'path'` = Layer 1 deterministic, `'manual'` = user set/confirmed. `'manual'` with `parent_session_id = NULL` means user explicitly unlinked — all auto-detection must skip. (Note: `'heuristic'` removed — Layer 2 only writes `suggested_parent_id`, never confirms directly.)
- `link_checked_at`: timestamp of last heuristic evaluation. Backfill skips sessions already checked.

### Constraints

- SQLite `ALTER TABLE` does not support FK constraints. Use a trigger for orphan protection:
  ```sql
  CREATE TRIGGER IF NOT EXISTS trg_sessions_parent_cascade
  AFTER DELETE ON sessions
  BEGIN
    UPDATE sessions SET parent_session_id = NULL, link_source = NULL, tier = NULL WHERE parent_session_id = OLD.id;
    UPDATE sessions SET suggested_parent_id = NULL WHERE suggested_parent_id = OLD.id;
  END;
  ```
  Parent deletion auto-restores children to top-level. Also sets `tier = NULL` so `backfillTiers()` re-evaluates on next maintenance cycle (SQLite triggers can't call TypeScript `computeTier()`).
- Max depth = 1 enforced at **all** write paths (Layer 1 adapter, backfill, manual API). Validation before every write:
  1. `parentId != sessionId` (no self-link)
  2. Parent session exists in DB
  3. Parent's own `parent_session_id IS NULL` (no depth > 1)
  Reject with error if any check fails.
- Base `CREATE TABLE` schema AND `ALTER TABLE` migration both updated (fresh DB + existing DB).
- Migration uses `PRAGMA table_info(sessions)` guard before each `ALTER TABLE ADD COLUMN` (project's existing idempotent pattern).

### Indexes

```sql
CREATE INDEX IF NOT EXISTS idx_sessions_parent ON sessions(parent_session_id, start_time DESC);
CREATE INDEX IF NOT EXISTS idx_sessions_suggested_parent ON sessions(suggested_parent_id, start_time DESC);
```

Composite index covers both `childSessions(parentId) ORDER BY start_time DESC` and `WHERE parent_session_id IS NULL` filtering.

### Query changes

- **Top-level queries** (HomeView, SessionListView): add `WHERE parent_session_id IS NULL`.
- **`childSessions(parentId, limit, offset)`**: returns children ordered by `start_time`, paginated.
- **`child_count`**: two-step — first LIMIT top-level parents, then COUNT children only for that batch. Avoids full-table correlated subquery.

## 2. Three-Layer Detection

### Layer 1: Path parsing (Claude Code subagents) — precise

Claude Code subagent path structure:
```
~/.claude/projects/<project>/<sessionId>/subagents/<agentId>.jsonl
```

- Extract `sessionId` from path as `parent_session_id`.
- Set `link_source = 'path'`.
- **Must check `link_source != 'manual'` before writing** — manual decisions are authoritative and must not be overwritten by reindex.
- Executes in Claude Code adapter `parseSessionInfo()` at index time. If parent doesn't exist yet (child indexed before parent), skip — Pass 1 backfill catches it after all sessions are indexed.
- Zero false positives. Deterministic.

### Layer 2: Content heuristic + temporal correlation — advisory

Detection conditions (all must match):
1. First user message matches known dispatch patterns:
   - Starts with `<task>` tag
   - Starts with `"Your task is to..."`
   - Starts with `"You are a...agent"` or similar agent dispatch boilerplate
2. Candidate parent exists:
   - `source` in `('claude-code', 'claude')`
   - Same project (or normalized `cwd` match as fallback)
   - Time overlap: `agent.start_time >= parent.start_time AND (parent.end_time IS NULL OR agent.start_time <= parent.end_time)`
3. Ambiguity rejection: if top 2 candidates score too close, refuse to link.

**Important: Layer 2 writes to `suggested_parent_id`, NOT `parent_session_id`.** Results are advisory. UI shows as dashed/weak association. User confirmation promotes to confirmed link.

`link_source` only tracks confirmed links (`parent_session_id`). When Layer 2 writes only `suggested_parent_id`, `link_source` stays NULL. Set `link_checked_at = now()` to prevent re-scanning. When user later confirms a suggestion, set `link_source = 'manual'`.

**Scoring criteria** for candidate parents (when multiple match):
1. Time proximity (60% weight): `1 / (1 + abs(agent.start_time - parent.start_time))` — closer start times score higher.
2. Project match (30% weight): exact project match = 1.0, normalized cwd match = 0.7, no match = 0.
3. Active session bonus (10% weight): parent `end_time IS NULL` (still running) = 1.0, ended = 0.5.
- **Ambiguity rejection**: if top 2 candidates' final scores differ by < 15%, refuse to link — write `link_checked_at` only.

**Performance**: use FTS index to find candidate sessions with dispatch keywords, not raw LIKE scans on message content.

**Execution**: post-processing after each index cycle. Only scans sessions where `link_checked_at IS NULL AND parent_session_id IS NULL AND link_source IS NULL`. Previously checked sessions are skipped.

**Race condition protection**: suggestion dismissal and confirmation use conditional updates:
```sql
UPDATE sessions SET suggested_parent_id = NULL, link_checked_at = ?
WHERE id = ? AND suggested_parent_id = ?  -- only if suggestion hasn't changed
```
Stale scanner writes are harmless — they only set `suggested_parent_id` which can be dismissed again.

### Layer 3: Manual override — authoritative

- MCP tool (extend existing or new `set_parent_session` tool): set/clear `parent_session_id`.
- Swift UI: session detail page provides "link to parent" / "unlink" actions (writes via daemon API, not direct Swift DB write).
- Set `link_source = 'manual'`.
- Manual unlink: set `parent_session_id = NULL, link_source = 'manual'`. Backfill sees `link_source = 'manual'` and skips — no infinite loop.
- Manual takes highest priority, overrides both Layer 1 and Layer 2.

### Tier lifecycle for linked children

`parent_session_id` replaces the UI-hiding function previously served by `tier = 'skip'` for agent sessions.

**On link (auto or manual):**
- If `tier = 'skip'`, upgrade to `'lite'` (enables FTS indexing).
- This ensures agent work content is searchable even though it's hidden from the main timeline.

**On unlink (manual unlink or parent deletion via trigger):**
- Re-evaluate tier via `computeTier()`. If the session still qualifies for `'skip'` (e.g. `agent_role IS NOT NULL` or `/subagents/` path), revert to `'skip'`.
- This prevents unlinked subagents from permanently polluting the main timeline as `'lite'` sessions.

## 3. Swift UI Changes

### Both HomeView and SessionListView

**Parent session card (has children):**
- Left side: disclosure triangle `▶` (collapsed) / `▼` (expanded)
- Right side: child count badge, e.g. "3 agents"
- Default state: collapsed

**Parent session card (has only suggested children):**
- Same layout but with dashed/dimmed triangle and badge, e.g. "~2 suggested"
- Visual distinction from confirmed children

**Suggested children display rule:**
- Sessions with only `suggested_parent_id` (no confirmed `parent_session_id`) **remain in the top-level list** — the link isn't confirmed yet, so they shouldn't disappear.
- The suggested parent also shows a dimmed badge so the user can discover the suggestion from either direction.
- User can confirm from the parent's expanded view or from the child's detail view. Confirming removes the child from top-level and nests it under the parent.

**Expanded child rows (compact mode):**
- Indented, visually subordinate to parent
- Each row: source icon + brief title (truncated `displayTitle`) + relative time
- Click navigates to full session detail
- Sorted by `start_time`
- **Max 20 visible** per parent. If more, show "show N more..." button (paginated load).

### HomeView specifics

- `recentSessions(limit: 8)` adds `WHERE parent_session_id IS NULL` — only top-level sessions.
- Lazy-load children on expand: `childSessions(parentId:)` queried on demand.
- Children don't count against the 8-session limit.

### SessionListView specifics

- Main list filters `WHERE parent_session_id IS NULL`.
- Agent filter mode interaction:
  - **All**: grouped collapsible view (parents expandable to show children)
  - **Hide**: children fully hidden, no triangle or badge shown
  - **Agents**: flat list of agent sessions only (for dedicated agent history browsing)

### SessionDetailView

- If session has `parent_session_id`: breadcrumb at top `← Parent: [parent title]` — clickable, navigates to parent.
- If session has `suggested_parent_id`: dimmed breadcrumb `← Suggested parent: [title]` with "Confirm" / "Dismiss" actions.
- If session has children: child session list at bottom, same compact row style.

### Search behavior

- FTS search results remain **flat** — child sessions appear as standalone hits.
- Each child search result shows breadcrumb `Parent: [title]` inline for context.
- Clicking navigates to child's detail view (with parent breadcrumb at top for traversal).

### Other surfaces

- Stats, timeline, activity views: continue counting all sessions (including children). No filtering change — these are aggregate metrics.
- Only Home and Sessions list views get the top-level-only filter.

## 4. Migration & Backfill

### Schema migration (idempotent)

In `migrate()`:
```sql
-- Columns
ALTER TABLE sessions ADD COLUMN parent_session_id TEXT
ALTER TABLE sessions ADD COLUMN suggested_parent_id TEXT
ALTER TABLE sessions ADD COLUMN link_source TEXT
ALTER TABLE sessions ADD COLUMN link_checked_at TEXT

-- Indexes
CREATE INDEX IF NOT EXISTS idx_sessions_parent ON sessions(parent_session_id, start_time DESC)
CREATE INDEX IF NOT EXISTS idx_sessions_suggested_parent ON sessions(suggested_parent_id, start_time DESC)

-- Orphan protection trigger (SQLite ALTER TABLE doesn't support FK)
CREATE TRIGGER IF NOT EXISTS trg_sessions_parent_cascade
AFTER DELETE ON sessions
BEGIN
  UPDATE sessions SET parent_session_id = NULL, link_source = NULL WHERE parent_session_id = OLD.id;
  UPDATE sessions SET suggested_parent_id = NULL WHERE suggested_parent_id = OLD.id;
END
```

Also update base `CREATE TABLE sessions` statement for fresh databases.

### Retroactive backfill (daemon maintenance)

Runs during daemon startup maintenance, after existing `backfillTiers()`:

**Pass 1 (Layer 1):**
```sql
-- Use agent_role index instead of LIKE '%/subagents/%' (avoids full table scan)
SELECT id, file_path FROM sessions
WHERE agent_role = 'subagent'
  AND parent_session_id IS NULL
  AND (link_source IS NULL OR link_source != 'manual')
LIMIT 500  -- bounded batch, resume on next maintenance cycle
```
Parse parent session ID from path. Validate parent exists and depth=1 before writing `parent_session_id` + `link_source = 'path'`.

**Pass 2 (Layer 2):**
```sql
-- Scan unchecked sessions for heuristic matching
SELECT id, file_path, start_time, project, cwd FROM sessions
WHERE parent_session_id IS NULL
  AND suggested_parent_id IS NULL
  AND link_checked_at IS NULL
  AND link_source IS NULL
  AND source IN ('gemini', 'codex')
LIMIT 500  -- bounded batch, same as Pass 1
```
For each candidate:
1. Read first user message via adapter.
2. Check dispatch pattern match.
3. If match, find candidate parent via FTS + temporal overlap.
4. Write `suggested_parent_id` if confident, always write `link_checked_at`.

**Tier upgrade pass:**
```sql
UPDATE sessions SET tier = 'lite'
WHERE parent_session_id IS NOT NULL
  AND tier = 'skip'
```

Both passes idempotent. Bounded batch size with resume cursor to avoid blocking startup.

### Incremental processing

- Layer 1: written at adapter index time for new sessions.
- Layer 2: batch scan after each index cycle for newly added sessions (`link_checked_at IS NULL`).
- Layer 3: user-triggered via daemon API anytime.

### Swift side

- `Session` model adds: `parentSessionId: String?`, `suggestedParentId: String?`, `linkSource: String?`
- GRDB row mapping updated to include new fields.
- No Swift-side writes — all parent links managed by Node via daemon API.
- New `DatabaseManager` read methods:
  - `childSessions(parentId:limit:offset:)` — paginated confirmed child fetch
  - `suggestedChildSessions(parentId:)` — suggested (unconfirmed) children for a parent
  - `childCount(parentIds:)` — batch count of confirmed children for visible parents
  - `suggestedChildCount(parentIds:)` — batch count of suggested children for visible parents
  - Both `nonisolated` + `readInBackground` per project convention.

## 5. Write Path for Manual Override (Swift → Node)

Swift UI does not write `parent_session_id` directly. Instead:
- Daemon exposes HTTP endpoints:
  - `POST /api/sessions/:id/link` — body: `{ parentId: string }` → sets confirmed parent
  - `DELETE /api/sessions/:id/link` → manual unlink (`link_source = 'manual'`, `parent_session_id = NULL`)
  - `POST /api/sessions/:id/confirm-suggestion` → promotes `suggested_parent_id` to `parent_session_id`:
    1. Re-validate parent exists and depth=1
    2. Set `parent_session_id = suggested_parent_id`
    3. Clear `suggested_parent_id = NULL`
    4. Set `link_source = 'manual'`, update `link_checked_at`
    5. Upgrade tier if needed (`skip` → `lite`)
  - `DELETE /api/sessions/:id/suggestion` → dismisses suggestion:
    - Request body: `{ suggestedParentId: string }` (the `:expected` value for conditional update)
    1. Conditional update: `WHERE suggested_parent_id = :suggestedParentId` (prevents race with scanner)
    2. Clear `suggested_parent_id = NULL`
    3. Set `link_checked_at = now()` (prevents re-suggestion of same pair)
- Swift `DaemonClient` calls these endpoints.
- Write-time validation: reject if target parent's `parent_session_id IS NOT NULL` (depth > 1).

## 6. Non-goals (explicit)

- **Sync/replication**: `parent_session_id` is local presentation state. Not included in `AuthoritativeSessionSnapshot`, sync payloads, or snapshot hash. May revisit if multi-device sync becomes a requirement.
- **Recursive nesting**: depth > 1 not supported. Enforced at write time.
- **Process tree mapping**: considered as Layer 2 alternative but only works for live sessions, not retroactive. May add as Layer 2 enhancement later.
- **Separate link table**: considered but adds join complexity for a straightforward parent pointer. FK + provenance columns on `sessions` is sufficient given local-only scope.
