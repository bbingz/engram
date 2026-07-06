# OpenCode Session Format

Last researched: 2026-06-21 (Engram session-format research workflow)

> **Evidence basis.** Three sources cross-checked; on conflict REAL data wins (discrepancies flagged inline).
> 1. **LIVE on-disk store (this machine)** — `~/.local/share/opencode/opencode.db` (224.1 MB, WAL mode; `-shm` 32 KB, `-wal` 0 B = checkpointed). 22 tables, OpenCode versions `1.2.6`–`1.17.8`. Counts: **21 projects, 386 sessions (all active, 0 archived; 165 root + 221 child), 7,445 `message` rows, 36,331 `part` rows, 190 `todo`, 26 `session_message`, 251 `event`**. 21 Drizzle migrations applied.
> 2. **Repo parity fixture** — `tests/fixtures/adapter-parity/opencode/input/sample.db` (1 session / 2 messages / 2 parts, `schemaVersion: 1`) + `success.expected.json`. Reflects the **older, narrower 18-column schema** the adapter was authored against. `tests/fixtures/opencode/` exists but is **EMPTY** (0 files); `tests/adapters/opencode.test.ts` builds a synthetic `sample.db` at runtime and deletes it.
> 3. **Engram adapters (codified)** — Swift product parser `macos/Shared/EngramCore/Adapters/Sources/OpenCodeAdapter.swift` (417 lines, authoritative); TS reference `src/adapters/opencode.ts` (314 lines, parity mirror).

---

## 1. Overview & TL;DR

**What/where/how.** OpenCode (the `sst/opencode` CLI/agent) stores its ENTIRE conversation corpus — every project, session, message, content block, todo, and event — inside **one shared SQLite database** at `~/.local/share/opencode/opencode.db`. There is **no per-session JSONL file and no per-message JSON file** (unlike Claude Code, Codex, or Gemini CLI). The schema is managed by **Drizzle ORM** (`__drizzle_migrations` + `migration` tables present; 21 migrations applied on this store).

**Mental model.** Three nesting layers, all read by Engram only in part:

```
┌─ project (21 rows) ──────────────────────────────────────────────┐
│  worktree, vcs, name, icon, …            (Engram: NOT read)       │
│                                                                   │
│  ┌─ session (386 rows) ───────────────────────────────────────┐  │
│  │  id=ses_…, directory(cwd), title(summary), parent_id,       │  │
│  │  time_created/updated/archived, model, cost, tokens_* …     │  │
│  │  Engram reads: id, directory, title, time_*; filters archived│ │
│  │                                                             │  │
│  │  ┌─ message (7,445 rows) ── LAYER 2: envelope ───────────┐  │  │
│  │  │  id=msg_…, session_id, time_created/updated,           │  │  │
│  │  │  data = JSON {role, time, tokens, cost, finish, …}     │  │  │
│  │  │  Engram reads: role + (assistant) tokens               │  │  │
│  │  │                                                        │  │  │
│  │  │  ┌─ part (36,331 rows) ── LAYER 3: content block ───┐  │  │  │
│  │  │  │  id=prt_…, message_id, session_id, time_created,  │  │  │  │
│  │  │  │  data = JSON discriminated by `type`:             │  │  │  │
│  │  │  │    text(3,509) reasoning(6,090) tool(12,147)      │  │  │  │
│  │  │  │    step-start(6,775) step-finish(6,738)           │  │  │  │
│  │  │  │    patch(1,032) file(25) compaction(14) subtask(1)│  │  │  │
│  │  │  │  Engram reads: ONLY type=="text"  ◄── scope limit │  │  │  │
│  │  │  └──────────────────────────────────────────────────┘  │  │  │
│  │  └────────────────────────────────────────────────────────┘  │  │
│  └────────────────────────────────────────────────────────────┘  │
└───────────────────────────────────────────────────────────────────┘
```

**TL;DR for Engram.** Engram opens the DB **read-only**, lists active sessions via one `SELECT … WHERE time_archived IS NULL`, fabricates a virtual locator `"{dbPath}::{sessionId}"` per session (no real file path exists), then reconstructs the transcript by JOINing `message ⋈ part` and keeping **only `type=="text"` parts**. Tool calls, reasoning traces, patches, files, and subtask dispatches (≈90% of all parts) are on disk but **never enter Engram's transcript or search index** — an intentional scope limit. Per-session size is computed via `SUM(length(data))` (NOT `statSync` of the shared 224 MB file).

---

## 2. On-disk layout & file naming

### Root + full tree (live, anonymized)

```
~/.local/share/opencode/
├── opencode.db            ← AUTHORITATIVE: all sessions/messages/parts (224.1 MB, WAL)
├── opencode.db-shm        ← shared-memory index (32 KB)
├── opencode.db-wal        ← write-ahead log (0 B here = checkpointed)
├── auth.json              ← provider OAuth/API credentials (0600)         (Engram: ignored)
├── account.json           ← logged-in account (0600)                      (Engram: ignored)
├── bin/                   ← downloaded provider/tool binaries              (Engram: ignored)
├── log/
│   └── opencode.log       ← runtime log, NOT session content              (Engram: ignored)
├── repos/                 ← (empty here) cloned repo working copies        (Engram: ignored)
├── snapshot/              ← per-project GIT object stores for file snapshots(Engram: ignored)
│   └── <project_id>/
│       └── <worktree_hash>/   ← a REAL bare-ish git repo:
│           ├── HEAD  config  description  index
│           ├── hooks/  info/  objects/  refs/
├── tool-output/           ← (empty here) overflow capture for large tool stdout (Engram: ignored)
└── storage/
    ├── migration/         ← migration markers                             (Engram: ignored)
    └── session_diff/      ← one JSON-array file PER SESSION (file-diff cache)
        ├── ses_2af53771bffeFqw1WrVD2KkPwT.json
        ├── ses_16ff4b89cffeYSrqS9o69S4jwK.json   (often `[]`)
        └── … (one per session)
```

Engram reads **only `opencode.db`**. Everything else (`snapshot/`, `session_diff/`, `tool-output/`, `repos/`, `bin/`, `log/`, `auth.json`, `account.json`) is ignored by the adapter.

> **Historical note.** Older OpenCode releases used a `storage/` JSON tree for transcript content; only vestigial sidecars (`migration/`, `session_diff/`) remain on the modern `sst/opencode` layout. Transcript content lives exclusively in the DB.
> **Confirmed (official):** [database.ts](https://github.com/sst/opencode/blob/dev/packages/core/src/database/database.ts) joins `Global.Path.data` with `opencode.db` and sets `PRAGMA journal_mode=WAL`, `synchronous=NORMAL`, `busy_timeout=5000`, `foreign_keys=ON`. [DeepWiki Storage and Database](https://deepwiki.com/sst/opencode/2.9-storage-and-database) confirms the DB is at `Global.Path.data/opencode.db`, that a migration engine "iterates through legacy JSON files and performs bulk inserts into SQLite" (confirming the `storage/` JSON tree is historical), and that VCS snapshots live at `Global.Path.data/snapshot/[projectID]/[hash]` for file-level undo/revert. Note: OpenCode's own writer uses a 5000 ms busy-timeout; Engram's read-only opener uses 30 s — a separate consumer, not a conflict.

### Naming grammar

| Entity | Column / file | Grammar | Live example |
|---|---|---|---|
| Session id | `session.id` | `ses_` + 26-char suffix (total 30) = **12 hex + 14 base62** (timestamp-prefixed → lexical sort ≈ chronological) | `ses_1182c0fb9ffegNnxixt6yu9qyO` |
| Message id | `message.id` | `msg_` + 26-char suffix (12 hex + 14 base62) | `msg_c74a763870014VGxpaTjyvK3Sy` |
| Part id | `part.id` | `prt_` + 26-char suffix (12 hex + 14 base62) | `prt_c74a76387002rncIB8Tc2txSAX` |
| Project id | `project.id` | 40-char hex (likely SHA-1 of the worktree path — derivation **inferred**, not source-confirmed) | `e8784f46a14602aaf5b98a02b9096ae8fc9ba30d` |
| `session_diff` file | filename | `<session_id>.json` | `ses_16ff4b89cffeYSrqS9o69S4jwK.json` |
| Snapshot store | dir | `snapshot/<project_id>/<worktree_hash>/` | `snapshot/e8784f…/332bbe4f…/` |

> **Confirmed (official):** the ID grammar is decoded from source ([id.ts](https://github.com/sst/opencode/blob/dev/packages/opencode/src/id/id.ts)). Prefixes are exactly `ses`/`msg`/`prt` (also `evt` for event, `wrk` for workspace, etc.). `create()` builds `prefix + '_' + 12 hex chars + randomBase62(LENGTH-12)` where `LENGTH=26` → 12 hex + 14 base62 = a 26-char suffix → 30 total. The leading 12 hex chars encode `BigInt(timestamp_ms) * 0x1000 + counter` as 6 bytes (ms-epoch + a 12-bit per-ms counter), so ascending IDs are lexically/chronologically sortable; `timestamp(id)` reverses it via `BigInt('0x'+hex) / 0x1000`. The earlier inference (base62 + ms epoch + counter) was essentially correct — refined here: only the trailing 14 chars are base62, the leading 12 are hex ([id.ts](https://github.com/sst/opencode/blob/dev/packages/opencode/src/id/id.ts), [session/schema.ts](https://github.com/sst/opencode/blob/dev/packages/opencode/src/session/schema.ts)).
> **Project id derivation (D2):** `project.id` is a text PK (`ProjectV2.ID`) FK-referenced by `session.project_id` — the column/relationship is source-confirmed, but the "SHA-1 of worktree path" derivation is **not** confirmed by source in this review. 40 hex chars is consistent with SHA-1, but treat the mechanism as inferred ([sql.ts](https://github.com/sst/opencode/blob/dev/packages/core/src/session/sql.ts)).

### Engram virtual locator

Because there is **no file path per session**, Engram synthesizes a virtual locator `"{dbPath}::{sessionId}"`, e.g.:

```
/Users/<user>/.local/share/opencode/opencode.db::ses_1182c0fb9ffegNnxixt6yu9qyO
```

It is split from the **right** (`lastIndexOf("::")` / Swift `.backwards`) so a `::` inside the db path (odd mount point) cannot corrupt the session id. See `OpenCodeAdapter.swift:116` / `:261-267`; `opencode.ts:75` / `:84-96`.

---

## 3. File lifecycle & generation

- **Storage tech: DB-not-file, but `message` rows are routinely re-touched.** Content is appended as new `message` + `part` rows during a turn, then the message row's `time_updated` advances as the turn/part stream finalizes. Live evidence: **7,439 / 7,445** messages have `time_updated > time_created`; only **6** have `time_updated == time_created` (and 0 have it earlier). So `time_updated` advances on essentially **every** message — it tracks turn/part-stream completion, NOT rare rewrites. The deltas are mostly small (6 equal, 31 <1s, 6,348 <1min, 1,060 ≥1min), consistent with finalization rather than later edits. There is no JSONL append; durability comes from SQLite WAL (`opencode.db-wal`).
- **Resume.** Resuming a session appends more `message`/`part` rows under the **same `session.id`**; `session.time_updated` advances. No new file is created (contrast with JSONL tools that may start a fresh transcript). Sub-agent / continued sessions get a non-NULL `parent_id` (221 of 386 here) and a `slug`.
- **No rollover.** Everything is one DB → no per-conversation file rotation. The only growth control is **context compaction** (`time_compacting`, `compaction` parts, `session_context_epoch` table), which summarizes old turns in-place.
- **Archive = soft tombstone.** Sessions are archived by setting `session.time_archived` (NOT by moving/deleting files). Engram's `WHERE time_archived IS NULL` (enumeration + `parseSessionInfo` + accessibility) makes archival invisible to Engram. Live store: 0 archived. Hard deletes cascade via FK `ON DELETE CASCADE` (deleting a session removes its message/part/todo rows). **Confirmed (official):** `time_archived` is a nullable soft-delete column that retains the row, and the FK cascade chain (project←session←message←part, plus todo/session_message/session_context_epoch from session) is explicit ([sql.ts](https://github.com/sst/opencode/blob/dev/packages/core/src/session/sql.ts), [DeepWiki Session Management](https://deepwiki.com/sst/opencode/2.1-session-management)).
- **WAL caveat.** Engram opens read-only (`SQLITE_OPEN_READONLY | SQLITE_OPEN_URI`, 30 s busy-timeout). Reading a live WAL DB read-only can miss the latest uncommitted writes until checkpoint, but won't corrupt; eventual indexing on the next scan is considered sufficient (no indexer-side `wal_checkpoint`/retry observed).
- **Side-effect artifacts** (outside the DB, NOT in Engram's model): file snapshots committed into per-project git object stores under `snapshot/<project_id>/<hash>/` (real git: `HEAD`, `objects/`, `refs/`, `index`), and per-session file-diff caches at `storage/session_diff/<session_id>.json` (often `[]`).

### How Engram discovers / enumerates sessions

1. `detect()` → `fileExists(~/.local/share/opencode/opencode.db)` (`OpenCodeAdapter.swift:100-102`; `opencode.ts:58-60`).
2. `listSessionLocators()` (Swift) / `listSessionFiles()` (TS) opens read-only and runs `SELECT id, directory, title, time_created, time_updated FROM session WHERE time_archived IS NULL ORDER BY time_updated DESC`, yielding one virtual locator per active session (`swift:108-114`; `ts:68-76`).
3. `parseSessionInfo(locator)` re-opens, fetches the one session row + its messages, derives start/end from first/last message `time_created` (falls back to `session.time_created`), counts contentful user/assistant messages, computes per-session `sizeBytes`.
4. `streamMessages` and `isAccessible` re-open per call. Swift `isAccessible` is backed by an actor-isolated `Phase4SQLiteAccessibilityCache` (`swift:61-85`) that keeps the open handle and re-checks `SELECT 1 FROM session WHERE id=? LIMIT 1` — fast existence revalidation without reopening the 224 MB file. TS reopens each call (`ts:264-280`) — behavioral parity, perf difference only.

There is **no filesystem walk** — discovery is a single SQL `SELECT`, and "session count" is a row count, never a file count.

---

## 4. Record / table taxonomy

The DB has **22 tables**. Engram touches exactly **3** (`session`, `message`, `part`). All others are present but unread.

| Table | Live rows | Read by Engram? | Purpose / key columns |
|---|---:|---|---|
| `session` | 386 | ✅ (5 cols) | one row per conversation; metadata, cwd, title, parent_id, time_*, model/cost/tokens rollups |
| `message` | 7,445 | ✅ (envelope) | one row per turn; `data` JSON = role + meta; FK → session |
| `part` | 36,331 | ✅ (text only) | one row per content block; `data` JSON keyed by `type`; FK → message AND session |
| `project` | 21 | ❌ | PK `id`; `worktree, vcs, name, icon_url, icon_color, time_* {created, updated, initialized}, sandboxes, commands, icon_url_override` (`time_initialized` is a distinct nullable column) |
| `todo` | 190 | ❌ | per-session todo list; PK `(session_id, position)`; `content, status, priority, time_*` |
| `session_message` | 26 | ❌ | **newer** event-style table; `id, session_id, type, time_*, data, seq`; live types confirmed to be only 2: `agent-switched`(13) / `model-switched`(13) |
| `event` | 251 | ❌ | generic event-sourcing log; `id, aggregate_id, seq, type, data`; live `type` enum is fully observable — 6 distinct types: `message.part.updated.1`, `message.updated.1`, `session.created.1`, `session.next.agent.switched.1`, `session.next.model.switched.1`, `session.updated.1` |
| `event_sequence` | — | ❌ | aggregate seq bookkeeping for `event` |
| `session_input` | 0 | ❌ | prompt inbox; `prompt, delivery, admitted_seq, promoted_seq` |
| `session_context_epoch` | 0 | ❌ | compaction baselines; `baseline, snapshot, baseline_seq, replacement_seq, revision, agent` |
| `session_share` | 0 | ❌ | `id, secret, url` |
| `workspace` | 0 | ❌ | `type, name, branch, directory, extra, project_id, time_used` |
| `project_directory` | — | ❌ | `project_id, directory, type, strategy` |
| `permission` | — | ❌ | `project_id, action, resource` (distinct from `session.permission` JSON) |
| `account` / `account_state` / `control_account` / `credential` | — | ❌ | auth/secrets (NOT session data) |
| `migration` / `data_migration` / `__drizzle_migrations` / `sqlite_sequence` | — | ❌ | Drizzle bookkeeping |

> **Schema-in-migration signal.** The coexistence of fully-populated `message`/`part` (7,445/36,331) with the sparse, newer `session_message` (26) indicates an in-progress event-sourcing migration in newer OpenCode builds. Engram correctly stays on the populated legacy `message`/`part` path. If a future OpenCode release moves transcript text into `session_message`, the adapter's `message ⋈ part` JOIN would need updating — not yet a problem.

---

## 5. Shared envelope / metadata fields

The `session` row is the record-level envelope; `message.data` is the per-turn envelope. Full session column inventory (live schema, 29 columns):

```sql
CREATE TABLE `session` (
  `id` text PRIMARY KEY, `project_id` text NOT NULL, `parent_id` text,
  `slug` text NOT NULL, `directory` text NOT NULL, `title` text NOT NULL,
  `version` text NOT NULL, `share_url` text,
  `summary_additions` integer, `summary_deletions` integer, `summary_files` integer,
  `summary_diffs` text, `revert` text, `permission` text,
  `time_created` integer NOT NULL, `time_updated` integer NOT NULL,
  `time_compacting` integer, `time_archived` integer,
  -- appended by later migrations (absent from v1 parity fixture):
  `workspace_id` text, `path` text, `agent` text, `model` text,
  `cost` real DEFAULT 0 NOT NULL,
  `tokens_input` integer DEFAULT 0 NOT NULL, `tokens_output` integer DEFAULT 0 NOT NULL,
  `tokens_reasoning` integer DEFAULT 0 NOT NULL,
  `tokens_cache_read` integer DEFAULT 0 NOT NULL, `tokens_cache_write` integer DEFAULT 0 NOT NULL,
  `metadata` text,
  CONSTRAINT fk_session_project_id_project_id_fk FOREIGN KEY (project_id)
    REFERENCES project(id) ON DELETE CASCADE);
-- indexes: session_project_idx, session_parent_idx, session_workspace_idx
```

> **Confirmed (official):** every column and index above matches `SessionTable` in [sql.ts](https://github.com/sst/opencode/blob/dev/packages/core/src/session/sql.ts) exactly (id PK, project_id NN FK→project ON DELETE CASCADE, workspace_id, parent_id, slug NN, directory NN, path, title NN, version NN, share_url, summary_additions/_deletions/_files, summary_diffs(json), metadata(json), cost real NN default 0, tokens_input/output/reasoning/cache_read/cache_write integer NN default 0, revert(json), permission(json Ruleset), agent, model(json `{id, providerID, variant?}`), time_created/time_updated, time_compacting, time_archived). Indexes: `session_project_idx`, `session_workspace_idx`, `session_parent_idx`. The reconstructed DDL is accurate. **Source-location note (D3):** the authoritative Drizzle table definitions live in `packages/core/src/session/sql.ts` (re-exported via `packages/opencode/src/storage/schema.ts`); `packages/opencode/src/session/schema.ts` holds only ID brand types (MessageID/PartID), not the table DDL.

| Column | Type | Meaning | Optional | Engram | Example (anon) |
|---|---|---|---|---|---|
| `id` | text PK | `ses_`-prefixed id | no | **read** → `id` + locator | `ses_1182c0fb9ffegNnxixt6yu9qyO` |
| `project_id` | text NN FK→project | owning project | no | ignored | `e8784f46a14602aaf5b98a02b9096ae8fc9ba30d` |
| `parent_id` | text? FK | parent session (sub-agent linking; indexed `session_parent_idx`) | yes | **ignored** (NOT mapped — see §10) | `null` (root) / `ses_…` (221/386) |
| `slug` | text NN | human slug (NOT the title) | no | ignored | `nimble-nebula` |
| `directory` | text NN | session cwd | no | **read** → `cwd` (`""` if NULL) | `/Users/<user>/-Code-/<proj>` |
| `title` | text NN | summary line | no | **read** → `summary` (empty → nil) | `Ping` |
| `version` | text NN | OpenCode version that wrote it | no | ignored | `1.17.8` (live spans `1.2.6`–`1.17.8`) |
| `share_url` | text? | share URL | yes | ignored | `null` |
| `summary_additions` / `_deletions` / `_files` | int? | session diff rollup | yes | ignored | `0/0/0` |
| `summary_diffs` | text? | serialized diffs | yes | ignored | `null` |
| `revert` | text? | revert/checkpoint JSON | yes | ignored | `null` |
| `permission` | text? (JSON) | array of permission rules | yes | ignored | `[{"permission":"todowrite","pattern":"*","action":"deny"}]` |
| `time_created` | int NN (epoch ms) | creation; **fallback** start time | no | **read** (fallback) | `1782005887047` |
| `time_updated` | int NN (epoch ms) | last touch; **list `ORDER BY` key** | no | **read** (ordering only) | `1782005893936` |
| `time_compacting` | int? | context-compaction marker | yes | ignored | `null` |
| `time_archived` | int? | soft-delete tombstone | yes | **filter** (`WHERE … IS NULL`) | `null` |
| `workspace_id` | text? FK | workspace | yes | ignored | `null` |
| `path` | text? | (newer) path | yes | ignored | `null` |
| `agent` | text? | active agent mode | yes | ignored | `build` (106/386 set) |
| `model` | text? (JSON) | model id blob | yes | **ignored** (Engram model=nil) | `{"id":"deepseek-v4-pro","providerID":"opencode-go","variant":"default"}` (106/386) |
| `cost` | real NN (def 0) | rolled-up session cost (USD) | no | **ignored** (re-derived per-message) | `0.03949974` (227/386 > 0) |
| `tokens_input` / `_output` / `_reasoning` / `_cache_read` / `_cache_write` | int NN (def 0) | rolled-up session usage | no | **ignored** (re-derived) | `22625 / 3 / 35 / 0 / 0` |
| `metadata` | text? (JSON) | newest metadata blob | yes | ignored | `null` |

> **Discrepancy (live ahead of fixture/adapter).** `workspace_id, path, agent, model, cost, tokens_*, metadata` (13 columns) were added by migrations `20260510033149_session_usage` / `20260511173437_session-metadata` and are **absent** from the v1 parity fixture. The adapter `SELECT`s only the original 5 columns (`id, directory, title, time_created, time_updated`), so behavior is unaffected — but Engram never surfaces OpenCode's native model or cost.

---

## 6. Message & content schema

### Layer 2 — `message` table (envelope)

```sql
CREATE TABLE `message` (
  `id` text PRIMARY KEY, `session_id` text NOT NULL,
  `time_created` integer NOT NULL, `time_updated` integer NOT NULL, `data` text NOT NULL,
  CONSTRAINT fk_message_session_id_session_id_fk FOREIGN KEY (session_id)
    REFERENCES session(id) ON DELETE CASCADE);
-- index: message_session_time_created_id_idx (session_id, time_created, id)
```

| Column | Type | Meaning | Engram | Example |
|---|---|---|---|---|
| `id` | text PK | `msg_` id | JOIN to `part.message_id`; merge key | `msg_ee7d3f378001HIAuJOPQd0Yd1F` |
| `session_id` | text NN FK | parent session | **read** (WHERE) | `ses_1182…` |
| `time_created` | int NN (ms) | message timestamp; first/last drive start/end | **read** → `timestamp` / `startTime` / `endTime` | `1782005887864` |
| `time_updated` | int NN (ms) | finalization marker — advances as the turn/part stream completes (7,439/7,445 > created; only 6 == created) | ignored | usually > created |
| `data` | text NN (JSON) | the envelope (role + meta) | **read** → `role`, (assistant) `tokens` | see below |

The `data` blob does **not** repeat `id`/`session_id` — those live only in columns.

> **Confirmed (official):** in [sql.ts](https://github.com/sst/opencode/blob/dev/packages/core/src/session/sql.ts) the JSON column on both `message` and `part` is named **`data`** (`data: text({ mode: 'json' }).notNull()`), NOT `info`. The TS types are `V1MessageData = Omit<SessionV1.Info, 'id'|'sessionID'>` and `V1PartData = Omit<SessionV1.Part, 'id'|'sessionID'|'messageID'>` — id/session_id/message_id are explicitly omitted from the blob and live only in columns, exactly as documented. (DeepWiki prose calls the column `info`; the source name `data` is authoritative.)

#### `message.data` — USER envelope

Live keys: `['role','time','agent','model','summary','tools','variant']` (minimal variant: `['role','time','summary','agent','model']`).

```json
{
  "role": "user",
  "time": { "created": 1782005887864 },
  "agent": "build",
  "model": { "providerID": "opencode-go", "modelID": "deepseek-v4-pro" },
  "summary": { "diffs": [] },
  "tools": { "todowrite": false, "todoread": false, "task": false },
  "variant": null
}
```

| Field | Type | Meaning | Optional | Engram |
|---|---|---|---|---|
| `role` | `"user"` | discriminator | no | **read** |
| `time.created` | int ms | create | no | ignored (uses DB col) |
| `agent` | string | dispatching agent | yes | ignored |
| `model` | `{providerID, modelID}` | target model | yes | ignored |
| `summary.diffs` | array | per-turn diff summary | yes | ignored |
| `tools` | obj `<name,bool>` | tool-enabled map | yes | ignored |
| `variant` | string\|null | variant | yes | ignored |

#### `message.data` — ASSISTANT envelope

Live keys: `['role','time','parentID','modelID','providerID','mode','agent','path','cost','tokens','finish']` (full variant adds `'error','summary','variant'`).

```json
{
  "role": "assistant",
  "time": { "created": 1771483653013, "completed": 1771483657730 },
  "parentID": "msg_c74a763870014VGxpaTjyvK3Sy",
  "modelID": "deepseek-v4-pro",
  "providerID": "opencode-go",
  "mode": "build",
  "agent": "build",
  "path": { "cwd": "/Users/.../mediahub", "root": "/Users/.../mediahub" },
  "cost": 0.03949974,
  "tokens": {
    "total": 22663, "input": 22625, "output": 3, "reasoning": 35,
    "cache": { "read": 0, "write": 0 }
  },
  "finish": "stop"
}
```

| Field | Type | Meaning | Optional | Engram |
|---|---|---|---|---|
| `role` | `"assistant"` | discriminator | no | **read** |
| `parentID` | text | user `msg_` answered (turn link) | yes | ignored |
| `mode` / `agent` | string | mode / agent | yes | ignored |
| `path` | `{cwd, root}` | exec dirs | yes | ignored |
| `cost` | float | message cost (USD) | yes | ignored |
| `tokens.total` | int | sum | yes | **ignored** (recomputed) |
| `tokens.input` | int | prompt tokens | yes | **read** → inputTokens |
| `tokens.output` | int | completion tokens | yes | **read** → outputTokens (with reasoning) |
| `tokens.reasoning` | int | reasoning tokens | yes | **read** → folded into outputTokens |
| `tokens.cache.read` | int | cache-read | yes | **read** → cacheReadTokens |
| `tokens.cache.write` | int | cache-create | yes | **read** → cacheCreationTokens |
| `modelID` / `providerID` | string | model + provider | yes | ignored |
| `time.created` / `time.completed` | int ms | gen window | yes | ignored |
| `finish` | string | finish reason (`stop`, `tool-calls`, …) | yes | ignored |
| `error` | obj | provider error | yes | ignored |
| `summary` | bool/obj | summarization flag | yes | ignored |
| `variant` | string | variant | yes | ignored |

Assistant **error** shape (degraded turn):

```json
{
  "name": "APIError",
  "data": {
    "message": "Invalid Authentication",
    "statusCode": 401,
    "isRetryable": false,
    "responseHeaders": { "...": "..." }
  }
}
```

Engram reads ONLY `role` (must be `user`/`assistant`; anything else skipped) and, for assistants, maps `tokens` → `TokenUsage`. It ignores `time`, `modelID`/`providerID`/`model`, `agent`, `mode`, `path`, `cost`, `finish`, `parentID`, `summary`, `error`.

> **Confirmed (official):** the message envelope fields match [v1/session.ts](https://github.com/sst/opencode/blob/dev/packages/core/src/v1/session.ts). `AssistantMessage` has `role:'assistant'`, `parentID` (MessageID), `modelID`, `providerID`, `cost`, `tokens{input/output/reasoning/cache{read,write}}`, optional `finish` (String). `UserMessage` has `role:'user'` with `providerID`/`modelID`. The token nesting (input/output/reasoning + cache.read/cache.write) matches the mapping in §9.

### Layer 3 — `part` table (content blocks — the actual transcript text)

```sql
CREATE TABLE `part` (
  `id` text PRIMARY KEY, `message_id` text NOT NULL, `session_id` text NOT NULL,
  `time_created` integer NOT NULL, `time_updated` integer NOT NULL, `data` text NOT NULL,
  CONSTRAINT fk_part_message_id_message_id_fk FOREIGN KEY (message_id)
    REFERENCES message(id) ON DELETE CASCADE);
-- indexes: part_session_idx (session_id); part_message_id_id_idx (message_id, id)
```

| Column | Type | Meaning | Engram | Example |
|---|---|---|---|---|
| `id` | text PK | `prt_` id | ignored | `prt_c74a76387002rncIB8Tc2txSAX` |
| `message_id` | text NN FK→message | **JOIN key** | **read** (JOIN + merge by msg) | `msg_c74a763870014VGxpaTjyvK3Sy` |
| `session_id` | text NN FK | parent session (denormalized; indexed) | ignored (uses JOIN) | `ses_38b589c7…` |
| `time_created` | int NN (ms) | order-within-message tiebreaker | secondary `ORDER BY` | `1771483653006` |
| `time_updated` | int NN (ms) | rewrite marker | ignored | `1771483653006` |
| `data` | text NN (JSON) | content block, **discriminated by `type`** | **read** (only `type=="text"`) | see below |

**Part `type` distribution (live, 36,331 parts):**

| `type` | count | data keys (live) | Engram uses? |
|---|---:|---|---|
| `tool` | 12,147 | `type, callID, tool, state{status,input,output,title,metadata,time}` | ❌ |
| `step-start` | 6,775 | `type` (+ `snapshot` on 5,530) | ❌ |
| `step-finish` | 6,738 | `type, reason, cost, tokens` (+ `snapshot` on 5,499) | ❌ |
| `reasoning` | 6,090 | `type, text, time` | ❌ |
| **`text`** | **3,509** | **`type, text`** (+ optional `time`, `synthetic`) | ✅ **only this** |
| `patch` | 1,032 | `type, hash, files` | ❌ |
| `file` | 25 | `type, mime, filename, url, source` | ❌ |
| `compaction` | 14 | `type, auto` (+ `overflow` on 12) | ❌ |
| `subtask` | 1 | `type, agent, command, description, model, prompt` | ❌ |

Union of all top-level part keys (live): `['type','text','time','callID','tool','state','reason','cost','tokens','hash','files','mime','filename','url','source','auto','overflow','snapshot','synthetic','metadata']`.

> **Confirmed (official):** the part `type` discriminated union matches [v1/session.ts](https://github.com/sst/opencode/blob/dev/packages/core/src/v1/session.ts) — `text` (optional `synthetic`), `reasoning`, `tool` (`callID`), `step-start`, `step-finish` (`cost` + `tokens{input/output/reasoning/cache{read,write}}`), `file`, `patch`, `compaction`, `subtask` (`model{providerID,modelID}`). All 9 documented types exist. Source additionally defines `snapshot`, `agent`, and `retry` as their own part literals (in addition to `snapshot` appearing as a top-level field on step parts) — this does not contradict any doc claim.

#### 6a. `type:"text"` (parsed — the ONLY type Engram reads)

```json
{
  "type": "text",
  "text": "<str len=834>",
  "time": { "start": 1771483678610, "end": 1771483678610 }
}
```

| Field | Type | Meaning | Optional | Engram |
|---|---|---|---|---|
| `type` | `"text"` | discriminator | no | **read** (trimmed, lowercased == `text`) |
| `text` | string | visible content | no | **read** → `content` (fallback `value`) |
| `time.start` / `.end` | int ms | render window | yes | ignored |
| `synthetic` | bool | injected (non-user) text — 21 rows | yes | ignored |

Engram accepts `text` OR `value` (`opencode.ts:239`; `swift:322-323,368-369`), drops empty/whitespace-only content. **Empty text → message excluded from counts** (Swift `contentfulRole`).

#### 6b. `type:"reasoning"` (ignored — on disk, never indexed)

```json
{ "type": "reasoning", "text": "<str len=…>", "time": { "start": …, "end": … } }
```

Same shape as `text` but `type=="reasoning"` → excluded. **Reasoning traces (6,090) are stored but never enter Engram's transcript or search index.**

#### 6c. `type:"step-start"` / `"step-finish"` (LLM step boundaries — ignored)

```json
{ "type": "step-start" }
```
```json
{
  "type": "step-finish", "reason": "tool-calls", "cost": 0,
  "tokens": { "total": 11660, "input": 9536, "output": 63, "reasoning": 23,
              "cache": { "read": 2061, "write": 0 } }
}
```

`step-finish` carries per-step `reason` / `cost` / `tokens` (same token shape as the message envelope). Many step rows also carry a top-level `snapshot` (git ref). All ignored.

#### 6d. `type:"patch"` / `type:"file"` / `type:"compaction"` (ignored)

```json
{ "type": "patch", "hash": "9fcfa4ef9a95a4b8ccdd1910f1f0e07388c5c026",
  "files": ["/Users/.../inference.js"] }
```
```json
{ "type": "file", "mime": "image/jpeg", "filename": "Bing_…jpg",
  "url": "<str len=198235>",
  "source": { "text": {"value":"[Image 1]","start":18,"end":27},
              "type": "file", "path": "Bing_…jpg" } }
```
```json
{ "type": "compaction", "auto": true }
```

`file.url` is a base64 **data URL** (~200 KB; a real per-session size driver). `source` ties the attachment to a span in the prompt. `compaction.auto` = automatic vs manual.

#### 6e. `type:"subtask"` (sub-agent dispatch — ignored; see §10)

```json
{
  "type": "subtask", "agent": "build",
  "description": "review changes [...]", "command": "review",
  "model": { "providerID": "kimi-for-coding", "modelID": "k2p5" },
  "prompt": "<str len=4657>"
}
```

### Reconstruction / merge model

Engram JOINs `message m JOIN part p ON p.message_id = m.id WHERE m.session_id=? ORDER BY m.time_created ASC, p.time_created ASC` (`swift:230-239`; `ts:208-215`). It keeps only `type=="text"` parts with non-empty content, then **concatenates all text parts of one message** with `\n` into a single `NormalizedMessage` (`messages(from:)` `swift:330-353`; `ts:225-256`). Emitted `timestamp` = the **message** `time_created`, NOT the part's `time.start`.

---

## 7. Tool calls & results

OpenCode stores tool calls richly — but **Engram does not consume any of them** (`toolCalls` is always `nil`, `toolMessageCount` hardcoded `0`). Documented here for completeness; all `type:"tool"` parts are dropped.

**Linkage model (distinctive).** Unlike Claude Code / Codex which split a tool request and its result across separate records, OpenCode stores the **call AND result in the SAME `part`**: `state.input` = request, `state.output`/`state.error` = result, joined by `state` lifecycle. The `callID` correlates with the provider's tool-call id.

Live state statuses: `completed` (11,674), `error` (472), `running` (1). Tools seen: `read, bash, grep, edit, glob, write, task, todowrite`, MCP-namespaced (`chrome-devtools_*`, `codegraph_codegraph_*`, `MiniMax_*`), `webfetch/websearch`, `skill`, `question`, `invalid`.

```json
{
  "type": "tool", "callID": "call_function_4cgbasugl504_1", "tool": "bash",
  "state": {
    "status": "completed",
    "input":  { "command": "...", "description": "..." },
    "output": "<...len=37116>",
    "title":  "...",
    "metadata": { "output": "<...>", "exit": 0, "description": "...", "truncated": false },
    "time": { "start": 1771483657599, "end": 1771483657647 }
  }
}
```

| Field | Type | Meaning | Optional |
|---|---|---|---|
| `type` | `"tool"` | discriminator | no |
| `callID` | string | **tool-call id** — links request↔result | no |
| `tool` | string | tool name | no |
| `state.status` | `pending\|running\|completed\|error` | lifecycle | no |
| `state.input` | obj | tool args (per-tool shape) | when started |
| `state.output` | string | result text | completed |
| `state.title` | string | label | yes |
| `state.metadata` | obj | per-tool extras (`exit`, `truncated`, `diff`, `filediff`, `diagnostics`, `sessionId`, `model`) | yes |
| `state.error` | string | error text | error only |
| `state.time.start` / `.end` | int ms | exec window | yes |

`error` state:
```json
{ "type":"tool","callID":"call_cb609c3a04814448b5b5f5bf","tool":"read",
  "state":{ "status":"error","input":{"filePath":"..."},
            "error":"Error: File not found: ...","time":{"start":…,"end":…}}}
```

`running` `task` adds `state.metadata.sessionId` (child session id) + `state.metadata.model`. `edit` `state.metadata`: `{ "diagnostics":{}, "diff":"<…>", "filediff":{"file":"…","before":"<…>","after":"<…>","additions":4,"deletions":4}, "truncated":false }`.

---

## 8. Reasoning / thinking

**Stored but NOT indexed.** OpenCode persists model chain-of-thought as `type:"reasoning"` parts (6,090 in this store) — same `{type, text, time}` shape as `text`. Engram drops them (only `type=="text"` survives). Reasoning is also tracked numerically in `message.data.tokens.reasoning`, which Engram **does** read (folded into `outputTokens`). So Engram captures the *count* of reasoning tokens but never the *content* of the reasoning trace.

---

## 9. Token usage & cost

OpenCode records usage at **three** levels; Engram derives from only one (per-message envelope):

1. **Session rollup** (`session.cost`, `session.tokens_input/output/reasoning/cache_read/cache_write`) — authoritative aggregates added by 2026-05 migrations. **Engram ignores these.**
2. **Per-message** (`message.data.tokens`, assistant only) — **the source Engram uses.**
3. **Per-step** (`step-finish.tokens`) — ignored.

### Per-message token mapping (assistant only)

| Engram `TokenUsage` | OpenCode `message.data.tokens` | Transform | Swift line (TS) |
|---|---|---|---|
| `inputTokens` | `tokens.input` | passthrough | `:390` (`:284`) |
| `outputTokens` | `tokens.output + tokens.reasoning` | **summed** | `:391` (`:285`) |
| `cacheReadTokens` | `tokens.cache.read` | passthrough | `:392` (`:286`) |
| `cacheCreationTokens` | `tokens.cache.write` | passthrough | `:393` (`:287`) |

Rules: `tokens.total` is **ignored** (recomputed). Usage returns `nil` if all four counters are 0 (`swift:394-401`; `ts:289-295`). Usage attaches **only to assistant** messages (`swift:381`; `ts:253`). Engram surfaces **no OpenCode cost** (the `cost` columns are unread).

> **Verified by parity fixture:** `outputTokens=50` = `output 45 + reasoning 5`; `inputTokens=123`, `cacheReadTokens=67`, `cacheCreationTokens=8`.
> **Confirmed (official):** OpenCode does maintain authoritative session-level rollups (`session.cost`, `tokens_input/output/reasoning/cache_read/cache_write`) as stored/updated counter columns ([sql.ts](https://github.com/sst/opencode/blob/dev/packages/core/src/session/sql.ts)). Whether Engram surfaces them instead of re-deriving per message is an Engram-internal design choice (not web-verifiable).
> **OPEN:** Whether the DB's session-level rollups always equal the sum of per-message envelopes was NOT verified for equality. The columns are defined as stored counters, not a guaranteed `= SUM(per-message)` invariant; they could diverge across compaction/summary turns or non-message token charges. (web-checked 2026-06-21: no authoritative source found asserting strict equality)

---

## 10. Subagent / parent-child / dispatch

OpenCode records parent/child lineage **natively in three places** — but the adapter consumes **none** of them (`parentSessionId: nil`, `swift:209`):

1. `session.parent_id` — confirmed parent link (FK, indexed `session_parent_idx`). **221 of 386 sessions are children** in this store.
2. `message.data.parentID` — per-turn link (assistant `msg_` → user `msg_`).
3. `subtask` part + `tool` part with `state.metadata.sessionId` (`task` tool) — carries the dispatched child session id at dispatch time.

Because the adapter hardcodes `parentSessionId: nil`, OpenCode subagent lineage is **invisible** to Engram's deterministic parent-detection (Layer 1). It can only be inferred by the heuristic Layer 2 backfill. This is a clear deterministic-lineage gap.

> **Confirmed (official):** `session.parent_id` natively records child/sub-agent lineage — [DeepWiki Session Management](https://deepwiki.com/sst/opencode/2.1-session-management) states it is "used for sub-agents or tasks spawned from a main conversation," and [sql.ts](https://github.com/sst/opencode/blob/dev/packages/core/src/session/sql.ts) shows it as a nullable, indexed (`session_parent_idx`) FK. The FK cascade chain is explicit: project←session (ON DELETE CASCADE), session←message (CASCADE), message←part (CASCADE), session←todo/session_message/session_context_epoch (CASCADE).
> **Engram-internal design — not web-verifiable:** whether a future Engram layer should wire `session.parent_id` → `NormalizedSessionInfo.parentSessionId` for Layer-1-style deterministic OpenCode subagent grouping, and whether Engram's heuristic detection reconciles with the native `parent_id`. The OpenCode side is settled (above); the consumption decision is an Engram product choice.

---

## 11. Summary / compaction

OpenCode has **in-place context compaction** (no file rollover):
- `session.time_compacting` — compaction-in-progress marker.
- `type:"compaction"` parts (14 here; `{type, auto, overflow?}`) — mark a compaction event in the transcript.
- `session_context_epoch` table (0 rows here) — compaction baselines/snapshots.
- `user` `message.data.summary.diffs` and `summary_additions/_deletions/_files` columns — per-turn diff summaries.

Engram consumes **none** of these. The `session.title` (mapped to Engram `summary`) is a generated title, not a compaction summary.

> **Confirmed (official):** [sql.ts](https://github.com/sst/opencode/blob/dev/packages/core/src/session/sql.ts) shows `session.time_compacting` (nullable integer, compaction-in-progress marker) and `SessionContextEpochTable` with `session_id` PK FK→session ON DELETE CASCADE, `baseline`, `agent`, `snapshot` (json SystemContext.Snapshot), `baseline_seq`, `replacement_seq`, `revision` — matching the compaction description above.

---

## 12. SQLite / DB internals

OpenCode IS a DB-backed tool — this is the core of the format. The 22-table schema is Drizzle-managed (`__drizzle_migrations`, 21 migrations applied; latest observed `20260612174303_project_dir_strategy`). Engram reads only `session` / `message` / `part`; their full DDL is in §5/§6. Key relational facts:

- **FK cascade chain:** `project ← session ← message ← part` (all `ON DELETE CASCADE`); `todo`, `session_message`, etc. cascade from `session`.
- **Indexes Engram benefits from:** `message_session_time_created_id_idx (session_id, time_created, id)` (drives the ordered message scan); `part_message_id_id_idx (message_id, id)` and `part_session_idx (session_id)` (drive the JOIN).
- **Per-session size via SQL** (NOT file stat) — see §15 gotcha #7.
- **Read-only access:** `SQLITE_OPEN_READONLY | SQLITE_OPEN_URI`, 30 s busy-timeout (`swift:8,14`); TS `{ readonly: true }` via `better-sqlite3` (`ts:67`).

For the per-table inventory (which tables exist, row counts, purpose, read-status) see §4.

---

## 13. Auxiliary files

| Artifact | Location | Engram | Purpose |
|---|---|---|---|
| WAL/SHM | `opencode.db-wal`, `opencode.db-shm` | opened read-only via main DB | SQLite durability/indexing |
| Auth | `auth.json`, `account.json` (0600) | ignored | provider OAuth/API creds, logged-in account |
| Provider binaries | `bin/` | ignored | downloaded tool/provider binaries |
| Runtime log | `log/opencode.log` | ignored | runtime log (NOT session content) |
| File snapshots | `snapshot/<project_id>/<hash>/` | ignored | real per-project git object stores (`HEAD`, `objects/`, `refs/`, `index`) |
| File-diff cache | `storage/session_diff/<session_id>.json` | ignored | per-session diff cache (often `[]`) |
| Tool-output overflow | `tool-output/` (empty here) | ignored | overflow capture for large tool stdout |
| Migration markers | `storage/migration/` | ignored | migration bookkeeping |

There is **no** Engram-readable index, sidecar, or cache for OpenCode beyond the DB itself.

---

## 14. Engram mapping

`file:line` is the **Swift product parser** (`OpenCodeAdapter.swift`); TS reference (`opencode.ts`) line in parentheses.

### Session → `NormalizedSessionInfo`

| Engram field | OpenCode source | Transform | Swift:line (TS) |
|---|---|---|---|
| `id` | `session.id` | passthrough; fallback to locator's sessionId | `:182` (`:172`) |
| `source` | constant | `.opencode` | `:88,:183` (`:50,:173`) |
| `summary` | `session.title` | empty → `nil` | `:196-199` (`:182`) |
| `cwd` | `session.directory` | passthrough; `""` if NULL | `:188` (`:176`) |
| `project` | — | **always `nil`** (not derived from `project.worktree`/`name`) | `:189` (TS omits field) |
| `model` | — | **always `nil`** (despite `session.model` present) | `:190` (TS omits) |
| `startTime` | first `message.time_created`, else `session.time_created` | epoch ms → ISO8601 (÷1000) | `:175-178` (`:130,:134`) |
| `endTime` | last `message.time_created` | **only if `messages.count > 1`**, else `nil` | `:185-187` (`:131-138`) |
| `messageCount` | derived | `userCount + assistantCount` (text-part-only — see §15) | `:191` (`:177`) |
| `userMessageCount` | derived | distinct `msg.id` where role=user AND ≥1 non-empty text part | `:172,:192` (`:140-145,:177`) |
| `assistantMessageCount` | derived | distinct `msg.id` where role=assistant AND ≥1 non-empty text part | `:173,:193` (`:146,:179`) |
| `toolMessageCount` | — | hardcoded `0` | `:194` (`:180`) |
| `systemMessageCount` | — | hardcoded `0` | `:195` (`:181`) |
| `sizeBytes` | `Σ length(message.data) + Σ length(part.data)` for this session | per-session SQL byte sum | `:201,:269-298` (`:156-169`) |
| `filePath` | virtual locator | `"{dbPath}::{id}"` | `:200` (`:183`) |
| `parentSessionId` | — | **always `nil`** — `session.parent_id` NOT read (§10) | `:209` (TS omits) |
| `suggestedParentId` / `agentRole` / `originator` / `origin` / `summaryMessageCount` / `tier` / `qualityScore` / `indexedAt` | — | all `nil` (set later by indexer/backfills) | `:202-210` (n/a) |

### Per-message → `NormalizedMessage`

| Engram field | OpenCode source | Notes | Swift:line (TS) |
|---|---|---|---|
| `role` | `message.data.role` | only `user`/`assistant` survive → `.user`/`.assistant` | `:361-362,:378` (`:237,:249`) |
| `content` | `part.data.text` (fallback `part.data.value`) | **only `type=="text"` parts**; empty dropped; multiple parts joined with `\n` | `:322-323,:337,:368-370` (`:238-240`) |
| `timestamp` | `message.time_created` | epoch ms → ISO8601 | `:374-375` (`:251`) |
| `toolCalls` | — | always `nil` (tool parts dropped) | `:345` (`:248` omits) |
| `usage` | `message.data.tokens` (assistant only) | see §9 token mapping | `:381` (`:253`) |

### Locator helpers

| Concern | Swift:line | TS:line |
|---|---|---|
| Default db path | `:93-95` | `:53-55` |
| `detect()` = fileExists | `:100-102` | `:58-60` |
| List query | `:108-114` | `:68-76` |
| Virtual locator build `"{dbPath}::{id}"` | `:116` | `:75` |
| Split from right (`lastIndexOf`/`.backwards`) | `:261-267` | `:84-96` |
| Read-only open | `:8,14` | `:67` |
| `isAccessible` (cached actor / reopen) | `:61-85,:249-259` | `:264-280` |
| Per-session byte sum | `:269-298` | `:156-169` |

---

## 15. Lineage, gotchas, version drift & edge cases

### Shared-format lineage

OpenCode is **architecturally distinct** from every other Engram source and is the **sole member** of the "shared SQLite relational, three-table (session/message/part), JSON-blob-in-column, virtual `db::id` locator" pattern:

- **NOT in the JSONL families.** The Gemini-CLI ↔ Qwen ↔ iFlow lineage uses per-project JSONL transcripts and the shared `Phase4AdapterSupport` JSON helpers (`isoFromMilliseconds`, `double`, `jsonObject`, defined in `GeminiCliAdapter.swift:3-58`). OpenCode **reuses those helper functions** but layers its own `Phase4SQLiteDatabase` reader on top (`OpenCodeAdapter.swift:4-59`) — it shares helpers, not on-disk format.
- **NOT in the `.vscdb` family.** Cursor / VS Code / Copilot / Cline use SQLite `.vscdb` with a VS Code key-value `ItemTable` (leveldb-style blob store). OpenCode shares **only the SQLite container**, not the schema — OpenCode is a normalized Drizzle relational schema. Closest cousin is Cursor at the "happens to use SQLite" level only.
- **Display grouping.** First-class standalone source: `SourceCatalog.swift:29` (`opencode` → `~/.local/share/opencode/opencode.db`), `SourceColors.swift:19` (color `Color.primary`), `:49`,`:63` (display "OpenCode"). Registered in `SessionAdapterFactory.swift` (default + alt sets) and not part of the cache-only Windsurf/Antigravity set. No family/parent grouping.

### Gotchas & edge cases

1. **Message counts massively understate reality (text-only predicate).** A message counts only if it has ≥1 non-empty `text` part (Swift `contentfulRole` `:311-328`, comment `:147-148`). Tool-only assistant turns vanish. REAL impact: assistant total ≈ 6,788 but assistant-with-text ≈ 2,501 → Engram reports ~37% of actual assistant turns. Intentional (counts must equal the streamed transcript), but Engram's OpenCode `messageCount` is a "visible text turns" count, not a turn count.

2. **TS ↔ Swift count divergence.** Swift counts only text-contentful messages (`contentfulRole`); **TS `parseSessionInfo` counts by raw `message.role`** (`ts:142-146`) — so for tool-only turns the TS reference reports a higher `messageCount` than the Swift product. The Swift product path is authoritative.

3. **Single-message sessions get `endTime = nil`.** Guard `messages.count > 1` (Swift `:185`; TS sets `endTime` whenever `messages.length > 0`, a minor TS↔Swift divergence). Also `startTime`/`endTime` derive from the `message` table, NOT `session.time_created/updated` — a session whose only activity is non-message rows falls back to `session.time_created` for start and `nil` end.

4. **`value` fallback is dead code today.** Adapters read `part.data.text ?? part.data.value`. **Live: `value` appears in 0 parts** (verified). The `value` path is legacy (older OpenCode part schema) and never fires.

5. **TS interface `MessageData.content[]` is fictional/legacy.** `opencode.ts:37` declares `content?: Array<{type, value?, text?}>` on the message blob, but **live: 0 messages have `data.content`** (verified) — text always lives in the `part` table. Stale type; harmless (streaming code reads parts correctly) but misleading.

6. **Test fixture schema ≠ live schema (drift).** The parity fixture's `session` table has only the original 18 columns (`schemaVersion: 1`; no `workspace_id`, `agent`, `model`, `cost`, `tokens_*`, `metadata`). Parity tests never exercise the newer columns — but the adapter only `SELECT`s the original 5, so behavior is unaffected. The fixture is pinned to an old OpenCode schema. `tests/fixtures/opencode/` is empty (runtime-generated).

7. **Per-session size, not whole-file size (the CLAUDE.md note).** All 386 sessions share ONE 224 MB file; `statSync(dbPath)` would attribute 224 MB to **every** session (386× over-count, ~86 GB phantom total). The fix sums `length(message.data) + length(part.data)` scoped to `session_id` (Swift `sessionPayloadSize:269-298`; TS `:156-169`, comment `:152-155`). Both implementations are byte-identical by construction. Verified by fixture: `sizeBytes: 276` = message + part byte sum.

8. **Wide version spread in one DB, stable message JSON.** Sessions span OpenCode **1.2.6 → 1.17.8** (top: `1.3.13`×70, `1.15.13`×61). The `message.data`/`part.data` JSON shape (role/time/tokens/parts) is **stable across this range** — a v1.2.6 assistant message has the same `tokens.{input,output,reasoning,cache.{read,write}}` nesting as v1.17.8. Migrations changed only `session`/`project` columns. The adapter is robust to version drift in practice.

9. **Read-only against a live WAL DB.** May miss uncommitted writes until checkpoint (won't corrupt). No indexer-side `wal_checkpoint`/retry observed; eventual indexing on next scan is the de-facto handling.

10. **Timestamps are epoch milliseconds (13 digits), ÷1000 before ISO** (Swift `isoFromMilliseconds`; TS `new Date(ms)`). `1782005887047` → `2026-06-21T01:38:07.047Z`. Both adapters handle ms correctly.

### Data Engram does NOT consume (explicit data-loss inventory)

1. **`session.parent_id`** (221/386 populated) → native subagent lineage invisible (§10).
2. **Session-level `cost` + `tokens_*` rollups** → ignored; usage re-derived per assistant message.
3. **`session.model` / `message.data.modelID`** (106/386 + per-message) → `model` always `nil`; Engram records no OpenCode model.
4. **`session.agent`, `mode`, `slug`, `version`, `workspace_id`, `share_url`, summary/diff stats, `revert`, `permission`, `metadata`.**
5. **All non-text parts** — tool (12,147), reasoning (6,090), patch (1,032), file (25), compaction (14), step-start/finish (13,513), subtask (1): ~33k of 36k parts dropped.
6. **`project`/`project_directory`/`workspace` tables** → `project` always `nil`; cwd comes only from `session.directory`.
7. **`tokens.total`** (uses the input/output/reasoning/cache breakdown instead).
8. **`todo`, `session_message`, `event`, `event_sequence`** tables entirely.

> **Open questions** (carried from research):
> - (a) **Engram-internal design — not web-verifiable:** should the text-only scope be widened to index tool/reasoning content for search? The format does store tool/reasoning content (confirmed), but whether Engram indexes it is an Engram product choice.
> - (b) **Engram-internal design — not web-verifiable:** should `session.parent_id` be wired to deterministic Layer-1 lineage? The OpenCode side is settled (`session.parent_id` natively records child/sub-agent lineage — see §10); the consumption decision is an Engram choice. [sql.ts](https://github.com/sst/opencode/blob/dev/packages/core/src/session/sql.ts)
> - (c) **Engram-internal design — not web-verifiable:** should session-level cost/token rollups be surfaced instead of re-derived? OpenCode maintains authoritative rollups (confirmed §9); surfacing them is an Engram choice. [sql.ts](https://github.com/sst/opencode/blob/dev/packages/core/src/session/sql.ts)
> - (d) do DB rollups always equal per-message sums? (web-checked 2026-06-21: no authoritative source found asserting strict equality — the columns are stored counters, not a documented invariant; see §9)
> - (e) **Confirmed (official):** the per-type `event.data` / `session_message.data` payload schema is decodable from [event.ts](https://github.com/sst/opencode/blob/dev/packages/core/src/session/event.ts) — each type's data shape is its `EventV2.define` schema. E.g. `session.next.agent.switched` payload = `{Base, messageID, agent:String}`; `session.next.model.switched` payload = `{Base, messageID, model: ModelV2.Ref}`. The source defines a far larger event universe (`session.next.step.started/ended/failed`, `tool.input.started/delta/ended`, `tool.called/progress/success/failed`, `text.started/delta/ended`, `reasoning.*`, `compaction.started/delta/ended`, `prompt.admitted/promoted`, etc.) than the 6 event / 2 session_message types observed in the live store; the "6 observed / 2 observed" counts are an empirical live-store snapshot, not the full source enum.

---

## 16. Appendix: real anonymized samples

> Anonymized: message/code text, secrets, paths, and image data URLs replaced with `<str len=N>`; all keys/structure verbatim from the live store.

### `session` row (live, 29 columns)

```
id                : ses_1182c0fb9ffegNnxixt6yu9qyO
project_id        : e8784f46a14602aaf5b98a02b9096ae8fc9ba30d
parent_id         : (NULL)                                      [221/386 non-NULL]
slug              : nimble-nebula
directory         : <cwd path>
title             : <generated title>
version           : 1.17.8
share_url         : (NULL)
summary_additions : 0    summary_deletions : 0    summary_files : 0
summary_diffs     : (NULL)    revert : (NULL)    permission : (NULL)
time_created      : 1782005887047
time_updated      : 1782005893936
time_compacting   : (NULL)
time_archived     : (NULL)                                      [0/386 archived]
workspace_id      : (NULL)    path : (NULL)
agent             : build                                       [106/386 set]
model             : {"id":"deepseek-v4-pro","providerID":"opencode-go","variant":"default"}
cost              : 0.03949974                                  [227/386 > 0]
tokens_input      : 22625    tokens_output : 3    tokens_reasoning : 35
tokens_cache_read : 0        tokens_cache_write : 0
metadata          : (NULL)
```

### `message.data` — user

```json
{
  "role": "user",
  "time": { "created": 1771483653004 },
  "summary": { "diffs": [] },
  "agent": "build",
  "model": { "providerID": "opencode", "modelID": "minimax-m2.5-free" }
}
```

### `message.data` — assistant

```json
{
  "role": "assistant",
  "time": { "created": 1771483653013, "completed": 1771483657730 },
  "parentID": "msg_c74a763870014VGxpaTjyvK3Sy",
  "modelID": "minimax-m2.5-free",
  "providerID": "opencode",
  "mode": "build",
  "agent": "build",
  "path": { "cwd": "/Users/.../Downloads", "root": "/" },
  "cost": 0,
  "tokens": { "total": 11660, "input": 9536, "output": 63, "reasoning": 23,
              "cache": { "read": 2061, "write": 0 } },
  "finish": "tool-calls"
}
```

### `part.data` — text (the only type Engram parses)

```json
{ "type": "text", "text": "<str len=834>",
  "time": { "start": 1771483678610, "end": 1771483678610 } }
```

### `part.data` — reasoning

```json
{ "type": "reasoning", "text": "<str len=…>",
  "time": { "start": 1771483655000, "end": 1771483657000 } }
```

### `part.data` — tool (completed)

```json
{ "type": "tool", "callID": "call_function_4cgbasugl504_1", "tool": "bash",
  "state": {
    "status": "completed",
    "input":  { "command": "<str>", "description": "<str>" },
    "output": "<str len=37116>",
    "title":  "<str>",
    "metadata": { "output": "<str>", "exit": 0, "description": "<str>", "truncated": false },
    "time": { "start": 1771483657599, "end": 1771483657647 } } }
```

### `part.data` — tool (error)

```json
{ "type": "tool", "callID": "call_cb609c3a04814448b5b5f5bf", "tool": "read",
  "state": { "status": "error", "input": { "filePath": "<str>" },
             "error": "Error: File not found: <str>",
             "time": { "start": 1771483657599, "end": 1771483657647 } } }
```

### `part.data` — step-start / step-finish

```json
{ "type": "step-start" }
```
```json
{ "type": "step-finish", "reason": "tool-calls", "cost": 0,
  "tokens": { "total": 11660, "input": 9536, "output": 63, "reasoning": 23,
              "cache": { "read": 2061, "write": 0 } } }
```

### `part.data` — patch / file / compaction / subtask

```json
{ "type": "patch", "hash": "9fcfa4ef9a95a4b8ccdd1910f1f0e07388c5c026",
  "files": ["/Users/.../inference.js"] }
```
```json
{ "type": "file", "mime": "image/jpeg", "filename": "<str>.jpg",
  "url": "<str len=198235>",
  "source": { "text": {"value":"[Image 1]","start":18,"end":27},
              "type": "file", "path": "<str>.jpg" } }
```
```json
{ "type": "compaction", "auto": true }
```
```json
{ "type": "subtask", "agent": "build",
  "description": "<str>", "command": "review",
  "model": { "providerID": "kimi-for-coding", "modelID": "k2p5" },
  "prompt": "<str len=4657>" }
```

### `session_message` row (newer event table — Engram ignores)

```
id           : <str>      session_id : ses_…    seq : 3
type         : model-switched          (or: agent-switched)
time_created : 1782005887047
data         : <json blob>
```

### `todo` row (Engram ignores)

```
session_id : ses_…    position : 0    status : completed    priority : high
content    : <str>    time_created/updated : <epoch ms>
```

### Parity fixture expected output (`success.expected.json`, schemaVersion 1)

```json
{
  "sessionInfo": {
    "id": "ses_test001", "source": "opencode",
    "startTime": "2026-02-02T02:40:01.000Z", "endTime": "2026-02-02T02:40:10.000Z",
    "cwd": "/Users/test/my-project", "summary": "<title>",
    "messageCount": 2, "userMessageCount": 1, "assistantMessageCount": 1,
    "toolMessageCount": 0, "systemMessageCount": 0,
    "sizeBytes": 276, "filePath": "<fixtureRoot>/opencode/input/sample.db::ses_test001"
  },
  "messages": [
    { "role": "user", "content": "<str>", "timestamp": "2026-02-02T02:40:01.000Z" },
    { "role": "assistant", "content": "<str>", "timestamp": "2026-02-02T02:40:10.000Z",
      "usage": { "inputTokens": 123, "outputTokens": 50,
                 "cacheReadTokens": 67, "cacheCreationTokens": 8 } }
  ]
}
```
(`outputTokens: 50` = output 45 + reasoning 5; `sizeBytes: 276` = message + part byte sum.)

---

## References (official sources)

Web confirmation performed 2026-06-21 (`web_access_ok=true`).

- [sst/opencode — session SQL table definitions (`packages/core/src/session/sql.ts`)](https://github.com/sst/opencode/blob/dev/packages/core/src/session/sql.ts)
- [sst/opencode — Identifier module / ID encoding (`packages/opencode/src/id/id.ts`)](https://github.com/sst/opencode/blob/dev/packages/opencode/src/id/id.ts)
- [sst/opencode — v1 session schema, part/message discriminated unions (`packages/core/src/v1/session.ts`)](https://github.com/sst/opencode/blob/dev/packages/core/src/v1/session.ts)
- [sst/opencode — session event payload schemas (`packages/core/src/session/event.ts`)](https://github.com/sst/opencode/blob/dev/packages/core/src/session/event.ts)
- [sst/opencode — database open + PRAGMAs + db filename (`packages/core/src/database/database.ts`)](https://github.com/sst/opencode/blob/dev/packages/core/src/database/database.ts)
- [sst/opencode — storage schema re-exports (`packages/opencode/src/storage/schema.ts`)](https://github.com/sst/opencode/blob/dev/packages/opencode/src/storage/schema.ts)
- [sst/opencode — session ID brands (msg/prt prefixes) (`packages/opencode/src/session/schema.ts`)](https://github.com/sst/opencode/blob/dev/packages/opencode/src/session/schema.ts)
- [DeepWiki — OpenCode Storage and Database](https://deepwiki.com/sst/opencode/2.9-storage-and-database)
- [DeepWiki — OpenCode Session Management](https://deepwiki.com/sst/opencode/2.1-session-management)
- [DeepWiki — OpenCode Message and Part Structure](https://deepwiki.com/sst/opencode/2.2-message-and-prompt-system)
