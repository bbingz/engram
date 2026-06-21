# Cursor Session Format — Definitive Engram Reference

Last researched: 2026-06-21 (Engram session-format research workflow)

> **Evidence basis.** PRIMARY = the **live on-disk store** on this machine (the
> user's real Cursor data): `~/Library/Application Support/Cursor/User/globalStorage/state.vscdb`
> (28.2 MB SQLite). Cross-checked against the repo fixtures
> `tests/fixtures/cursor/state.vscdb` (3 rows) and
> `tests/fixtures/adapter-parity/cursor/{input/state.vscdb, success.expected.json}`,
> and against both Engram adapters: the Swift product parser
> `macos/Shared/EngramCore/Adapters/Sources/CursorAdapter.swift` and the
> TypeScript reference `src/adapters/cursor.ts`. **On conflict REAL data wins;**
> discrepancies are flagged inline. All quoted values are anonymized to
> structure-only (keys/types verbatim, message text/code/secrets/paths redacted).
>
> Live-store census actually executed for this doc (`sqlite3` over the global DB):
> `cursorDiskKV` key prefixes — `bubbleId` 524, `checkpointId` 369,
> `codeBlockDiff` 174, `composerData` 64, `agentKv` 46, `messageRequestContext` 24,
> (empty-prefix) 9, `composerVirtualRowHeights` 1. Of the 64 composers:
> **5 NULL value / 51 empty / 4 headers-only / 4 inline**. Of 6 composers with a
> summary, **all 6** store `latestConversationSummary.summary` as an **object**
> (0 strings). Bubble `type` distribution: **71 user / 444 assistant**.

---

## 1. Overview & TL;DR

**What.** Cursor is a **VS Code fork** and inherits VS Code's persistence model:
a SQLite key/value database named `state.vscdb`. But it does **not** store chat
in VS Code's tables — it adds a Cursor-specific table **`cursorDiskKV`** inside
the *global* storage DB and writes all conversation data there.

**Where.** `~/Library/Application Support/Cursor/User/globalStorage/state.vscdb`
(macOS). A **single shared file holds every session across all time** — there is
no per-session or per-day file.

**How saved.** Each AI session is a **"composer"** stored as one row
`composerData:<composerId>` in `cursorDiskKV`. Each message is a **"bubble"**.
Messages live in one of two mutually exclusive layouts: **inline** (embedded in
`composerData.conversation[]`) or **headers-only / separate** (a manifest
`fullConversationHeadersOnly[]` in the composer + one `bubbleId:<composerId>:<bubbleId>`
row per message). Writes are **in-place upserts** (`UNIQUE ON CONFLICT REPLACE`),
never append.

**Mental model.**
- Composer = Engram **session** (one composer → one Engram session).
- Bubble = Engram **message** (`type` 1 = user, 2 = assistant; no system/tool role).
- Tool calls + their results are **nested inside the bubble** that issued them
  (`toolFormerData`), not separate records. Usually the assistant bubble, but
  **13/291 live `toolFormerData` payloads sit on USER (type-1) bubbles**, so the
  nesting is not strictly assistant-only (278 assistant + 13 user).
- Cursor does NOT bind a composer to a workspace; cwd is best-effort inference.

```
                ┌──────────────────────────────────────────────────────────────┐
                │  globalStorage/state.vscdb   (SQLite, ONE file, 28.2 MB)        │
                │                                                                │
   Engram reads │  ┌── ItemTable ───────────────────────────────┐  (IGNORED)    │
   ONLY this DB │  │  composer.composerHeaders  (global catalog) │               │
   read-only    │  │  workbench.panel.*chat*    (UI state)       │               │
                │  └────────────────────────────────────────────┘               │
                │  ┌── cursorDiskKV ─────────────────────────────────────────┐   │
                │  │  composerData:<cid>          (64)  SESSION   <-- enumerate│   │
                │  │     ├─ conversation[]            inline bubbles (4)       │   │
                │  │     └─ fullConversationHeadersOnly[] -> points to:        │   │
                │  │  bubbleId:<cid>:<bid>        (524) MESSAGE  (separate, 4) │   │
                │  │       └─ toolFormerData          tool call + result       │   │
                │  │  checkpointId:<uuid>        (369)  FS snapshot  (IGNORED) │   │
                │  │  codeBlockDiff:<uuid>       (174)  edit diff    (IGNORED) │   │
                │  │  agentKv:blob:<sha256>      (46)   raw API msg  (IGNORED) │   │
                │  │  messageRequestContext:..   (24)   req context  (IGNORED) │   │
                │  │  composerVirtualRowHeights  (1)    UI cache     (IGNORED) │   │
                │  └─────────────────────────────────────────────────────────┘   │
                └──────────────────────────────────────────────────────────────┘

   workspaceStorage/<32-hex>/state.vscdb   (per-workspace pointer index, IGNORED by CursorAdapter)
```

**Layering (4 nesting layers, do not conflate):**
1. **DB file** — `state.vscdb` (one shared file).
2. **Table / namespace** — `cursorDiskKV` rows keyed by `prefix:id[:id]`.
3. **Record** — composer (session) row, bubble (message) row, etc.
4. **Content sub-object** — `timingInfo`, `tokenCount`, `toolFormerData`,
   `context`, `codeBlocks` nested inside a record.

---

## 2. On-disk layout & file naming

**Root (both adapters hard-code this and open read-only):**

| Adapter | Default path | file:line |
|---|---|---|
| Swift (product) | `~/Library/Application Support/Cursor/User/globalStorage/state.vscdb` | `CursorAdapter.swift:9-11` |
| TypeScript (reference) | `~/Library/Application Support/Cursor/User/globalStorage/state.vscdb` | `cursor.ts:36-47` |

**Directory tree (verified live):**

```
~/Library/Application Support/Cursor/User/
├── globalStorage/
│   └── state.vscdb                # <-- AUTHORITATIVE: all chat data (cursorDiskKV) + catalogs (ItemTable)
├── workspaceStorage/
│   ├── 02822dc51e1c79be6b4f8feb18737291/   # 32-hex workspace hash
│   │   ├── workspace.json         # { "folder": "file:///path/to/project" }  -> hash -> repo
│   │   ├── state.vscdb            # per-workspace UI state + composer.composerData pointer index
│   │   ├── state.vscdb.backup     # SQLite backup copy of the above
│   │   └── anysphere.cursor-retrieval/   # Cursor codebase-index extension state
│   ├── 04949500e42cbeac22dbcc972e071646/
│   └── … (28 workspace dirs)
├── History/                       # VS Code per-FILE edit history (NOT chat) — dirs like "-12d18da6"
├── snippets/
├── settings.json
└── keybindings.json
```

| File / DB kind | Location | Role | Read by Engram? |
|---|---|---|---|
| `globalStorage/state.vscdb` | global | **Sole source** of conversation data (`cursorDiskKV`) + global catalogs (`ItemTable`) | YES (only this) |
| `workspaceStorage/<hash>/state.vscdb` | per-workspace | UI panel state + `composer.composerData` pointer list (composerIds only, no content) | NO |
| `workspaceStorage/<hash>/state.vscdb.backup` | per-workspace | Backup snapshot of the workspace DB | NO |
| `workspaceStorage/<hash>/workspace.json` | per-workspace | Maps the 32-hex hash to the project folder URI (only reliable composer→folder map) | NO |
| `History/` | global | VS Code per-file edit history (timestamps + content snapshots) — unrelated to chat | NO |

**Naming grammar — `cursorDiskKV` key namespaces** (`prefix:id[:id]`), live counts:

| Key pattern | Count | Meaning | Consumed |
|---|---|---|---|
| `composerData:<composerId>` | 64 | One AI session ("composer"). `composerId` = UUIDv4. **The session record Engram enumerates.** | YES |
| `bubbleId:<composerId>:<bubbleId>` | 524 | One message ("bubble") in the separate/headers-only format. Both ids UUIDv4. | YES |
| `checkpointId:<composerId>:<checkpointId>` | 369 | Per-message file-state checkpoint (undo/restore of agent edits) | no |
| `codeBlockDiff:<id>:<id>` | 174 | Diff of a generated code block vs base version | no |
| `agentKv:blob:<sha256>` | 46 | Content-addressed raw API `{role,content}` message blobs | no |
| `messageRequestContext:<composerId>:<bubbleId>` | 24 | Per-request context (rules, dir results, summarized composers, terminals) | no |
| (empty prefix) | 9 | misc / inline-diff editor state (`inlineDiffsData`, `inlineDiffs-<id>`) | no |
| `composerVirtualRowHeights:<composerId>:_recentIds` | 1 | UI render cache (virtual list row heights) | no |

**Topology nuance (verified).** Conversation content lives ONLY in the
**global** DB. The per-workspace `state.vscdb` stores `composer.composerData`
whose `allComposers[]` is just a pointer list (`composerId`, `createdAt`,
`unifiedMode`, `forceMode`) into the global store — no message bodies. A single
composer can be referenced from a workspace index but its data is global. Engram
intentionally ignores `workspaceStorage/` and reads everything from the one
global DB. (Note: the separate `VsCodeAdapter` is the one that crawls
`Code/User/workspaceStorage/`; `CursorAdapter` never does.)

**Legacy caveat (corrected).** This global-only design is correct for MODERN
Cursor. However, LEGACY-era Cursor stored chat inside the per-workspace
`ItemTable` key `workbench.panel.aichat.view.aichat.chatdata` (`tabs[]`/`bubbles[]`).
Such legacy chats can exist ONLY in `workspaceStorage/` and would be missed by a
global-DB-only adapter — a real (if unquantified) gap
([source](https://dasarpai.com/dsblog/cursor-chat-architecture-data-flow-storage/)).

Example keys (live, ids real but non-identifying):
```
composerData:0066a5aa-1757-44bf-a7c4-1a3d6ee3c790
bubbleId:191ae4eb-4c8f-4cb3-8531-b783611e03a6:02fcf474-adc1-42b7-8933-c3904ebfc5d8
checkpointId:191ae4eb-4c8f-4cb3-8531-b783611e03a6:<checkpointUuid>
```

---

## 3. File lifecycle & generation

- **Storage tech: SQLite, not JSONL / leveldb / per-message files / gRPC cache.**
  Live schema (both tables identical):
  ```sql
  CREATE TABLE ItemTable    (key TEXT UNIQUE ON CONFLICT REPLACE, value BLOB);
  CREATE TABLE cursorDiskKV (key TEXT UNIQUE ON CONFLICT REPLACE, value BLOB);
  ```
  `value` is a BLOB that stores **UTF-8 JSON text** in every relevant row
  (occasionally NULL for tombstoned rows — 5/64 `composerData` rows are NULL;
  the adapters guard against this).

- **Append vs rewrite: in-place upsert (rewrite), never append.** The
  `UNIQUE ... ON CONFLICT REPLACE` clause is the key lifecycle signal — each new
  turn upserts the composer row (`lastUpdatedAt`, `status`, embedded
  `conversation`) and inserts/updates bubble rows. There is no append-only log;
  the live DB is the current state. Engram opens read-only and never writes.

- **DB vs file: DB.** No per-message JSON files exist. The two layouts (§4)
  differ only in whether messages are embedded in the composer row or in their
  own `bubbleId:` rows — both are SQLite rows.

- **Resume.** Reopening a composer continues writing under the **same
  `composerId`** — `lastUpdatedAt` advances while `createdAt` stays fixed. No new
  file/key is created on resume.

- **Rollover: none.** No per-day / per-size file split. All composers across all
  time share the single `globalStorage/state.vscdb`. Growth is unbounded within
  one file (28.2 MB here). Both adapters therefore compute per-session size as
  **just that composer's JSON payload + its separate bubble rows' raw bytes**,
  NOT the whole file (`CursorAdapter.swift:72-77,95`, `cursor.ts:99-119,149`).

- **Archive / delete.** Cursor marks composers via `isArchived` / `isDraft`
  flags in the `composer.composerHeaders` catalog (ItemTable). Deletion removes
  the `composerData:` row (and may leave NULL `value` tombstones). Engram does
  not filter on archive state; it enumerates every composer with a non-empty id.

- **Format migration.** Older sessions use the **inline** `conversation` array;
  newer ones use **separate** `bubbleId:` rows (`_v: 2`). The ItemTable key
  `composer.planMigrationToHomeDirCompleted` confirms Cursor has run at least one
  storage-location migration. Engram's two-path fallback exists precisely to span
  this evolution.

- **Backups.** Each workspace keeps a `state.vscdb.backup`; the global DB relies
  on SQLite WAL. Engram reads neither backups nor WAL explicitly.

---

## 4. Record / line / table taxonomy

There are exactly **2 SQLite tables** (`ItemTable`, `cursorDiskKV`) and the
following **record types** keyed within `cursorDiskKV` (plus singleton keys in
`ItemTable`):

| Record | Key | Layer | Purpose | Consumed |
|---|---|---|---|---|
| Composer | `composerData:<cid>` | session | Envelope: timestamps, mode, summary, context, optional inline `conversation[]` | YES |
| Header manifest | `composerData.fullConversationHeadersOnly[]` | sub-object | Ordered `{bubbleId,type}` pointers into separate bubble rows | indirectly (via LIKE) |
| Bubble | `bubbleId:<cid>:<bid>` | message | One user/assistant turn; nests `toolFormerData`, `codeBlocks`, `tokenCount`, `timingInfo` | YES |
| Checkpoint | `checkpointId:<cid>:<id>` | aux | Filesystem snapshot for undo/restore of agent edits | no |
| Code-block diff | `codeBlockDiff:<id>:<id>` | aux | Line-range diff of a suggested edit vs base v0 | no |
| Agent KV blob | `agentKv:blob:<sha256>` | aux | Content-addressed raw provider `{role,content}` messages | no |
| Request context | `messageRequestContext:<cid>:<bid>` | aux | Per-request rules / dir results / summarized composers / terminals | no |
| UI row-height cache | `composerVirtualRowHeights:<cid>:_recentIds` | aux | Virtual-list render cache | no |
| Global catalog | `ItemTable['composer.composerHeaders']` | catalog | Cross-session list (status, line stats, archive flags) | no |
| Workspace index | `ItemTable['composer.composerData']` (per-workspace DB) | index | composer→folder mapping | no |

### The two conversation storage formats (the central lifecycle fork)

A composer's messages are stored in one of **two** mutually-exclusive ways. Both
adapters handle them with a fallback chain (`CursorAdapter.swift:191-219`,
`cursor.ts:106-120` / `188-202`):

1. **Inline (legacy)** — `composerData.conversation[]` is a non-empty array of
   bubble objects inline in the composer row. `rawBubbleBytes = 0` (nothing
   separate). **Live: 4 / 64.**
2. **Headers-only / separate (modern)** — `composerData.conversation` is
   empty/absent; `composerData.fullConversationHeadersOnly[]` is an ordered
   `{bubbleId, type}` manifest and each message is its own
   `bubbleId:<cid>:<bid>` row. Engram fetches these with
   `WHERE key LIKE 'bubbleId:<cid>:%' ORDER BY rowid ASC`. **Live: 4 / 64.**
3. **Empty / draft** — neither a non-empty `conversation` nor matching
   `bubbleId:` rows → emits a 0-message session. **Live: 51 / 64 (~80%).**
4. **NULL value** — `composerData:` key present, `value IS NULL` → skipped by the
   guard. **Live: 5 / 64.**

Resolution order in both adapters: try inline `conversation` first; only if empty
query the separate `bubbleId` rows. The two formats are never merged. Note: the
adapter does NOT read `fullConversationHeadersOnly` directly — it relies on the
`bubbleId:` LIKE prefix and **rowid order** (see §15 gotcha #1).

---

## 5. Shared envelope / metadata fields — `composerData:<composerId>`

The composer row is the session-level record (~35 distinct top-level keys
observed live; the 27 keys present on one inline composer were:
`composerId, richText, hasLoaded, text, conversation, status, context,
gitGraphFileSuggestions, userResponsesToSuggestedCodeBlocks, generatingBubbleIds,
isReadingLongFile, codeBlockData, originalModelLines, newlyCreatedFiles,
newlyCreatedFolders, tabs, selectedTabIndex, lastUpdatedAt, createdAt,
hasChangedContext, capabilities, name, codebaseSearchSettings,
isFileListExpanded, unifiedMode, forceMode, isAgentic`).

| Field | Type | Meaning | Optional | Consumed | Example (anonymized) |
|---|---|---|---|---|---|
| `_v` | int | Schema version of this record | no | no | `3` (live varies: `3`×43, absent×11, `1`×3, `16`×2) |
| `composerId` | string (uuid) | Session id → Engram `id` | no | **yes** | `"191ae4eb-…-b783611e03a6"` |
| `name` | string | User/auto **chat title** | yes (8/64) | **NO** (no title field in NormalizedSessionInfo) | `"<chat title>"` |
| `text` | string | Current draft input box text | no (often `""`) | no | `""` |
| `richText` | string | Lexical/ProseMirror JSON of draft input | yes | no | `"<str len=176>"` |
| `status` | string | Session run state | yes | no | `"completed"`, `"aborted"` |
| `createdAt` | int (epoch **ms**) | Session start → `startTime` | no* | **yes** | `1738226420089` |
| `lastUpdatedAt` | int (epoch ms) | Last write → `endTime` (only if ≠ createdAt) | no* | **yes** | `1744430839587` |
| `conversation` | array<Bubble> | **Inline** full bubbles (legacy variant) | yes (empty when split) | **yes (when present)** | `[{type:1,…}]` |
| `fullConversationHeadersOnly` | array<{bubbleId,type[,serverBubbleId]}> | Ordered bubble manifest (modern) | yes | no (LIKE used instead) | see §6.0 |
| `conversationMap` | object | Map keyed by bubbleId (usually `{}` when split) | yes | no | `{}` |
| `generatingBubbleIds` | array | Bubbles still streaming | yes | no | `[]` |
| `latestConversationSummary` | object | `{ summary, lastBubbleId }` → Engram `summary` (≤200 chars) | yes (6/64) | **partially (see drift)** | see below |
| `context` | object | Attached files/folders/terminals/git/docs/rules + `mentions` | no | TS only (cwd) | see below |
| `codeBlockData` | object (URI → [CodeBlock]) | All model-suggested edits, per-file, versioned | yes | no | see below |
| `originalModelLines` | object (URI → lines) | Pre-edit file line snapshots | yes | no | `{}` |
| `usageData` | object (model → `{costInCents,amount}`) | **Per-session cost/usage** | yes (often `{}`) | no | `{ "claude-3.5-sonnet": { "costInCents":611, "amount":80 } }` |
| `tokenCount` | int | Total session token count | yes (9/64) | **NO** (per-bubble used instead) | `9693` |
| `unifiedMode` | string | `"agent"` / `"chat"` / `"edit"` | yes | no | `"agent"` |
| `forceMode` | string | Forced sub-mode | yes | no | `"edit"` |
| `isAgentic` | bool | Agent (multi-tool) vs plain chat | yes | no | `true` |
| `capabilities` | array | Enabled capability descriptors | yes | no | `[]` |
| `latestChatGenerationUUID` | string | Last generation id | yes | no | `"<uuid>"` |
| `tabs`, `selectedTabIndex` | array / int | Multi-tab composer UI | yes | no | — |
| `newlyCreatedFiles`, `newlyCreatedFolders` | array | FS objects created this session | yes | no | `[]` |
| `gitGraphFileSuggestions` | array | Git suggestions | yes | no | `[]` |
| `userResponsesToSuggestedCodeBlocks` | array | Accept/reject of suggestions | yes | no | `[]` |
| `allAttachedFileCodeChunksUris` | array | URIs of attached code chunks | yes | no | `[]` |
| `codebaseSearchSettings` | object | Search config | yes | no | `{}` |
| `hasLoaded`, `hasChangedContext`, `isFileListExpanded`, `isReadingLongFile` | bool | UI/load flags | yes | no | `false` |

\* `createdAt`/`lastUpdatedAt` are required in practice but the Swift adapter
derives `createdAt` defensively: `composerData.createdAt` → first visible
bubble's `timingInfo.clientStartTime` → `lastUpdatedAt` → `0`
(`CursorAdapter.swift:64-67`). Timestamps convert via
`isoFromMilliseconds = isoFromSeconds(ms / 1000.0)`
(`GeminiCliAdapter.swift:49-51`). The TS adapter naively does
`new Date(createdAt).toISOString()` (`cursor.ts:136`).

**`latestConversationSummary` — VERSION-DRIFT BUG (REAL vs adapter conflict).**
Inner keys verified live: outer = `[summary, lastBubbleId]`; inner
`summary` object = `[summary, truncationLastBubbleIdInclusive,
clientShouldStartSendingFromInclusiveBubbleId, previousConversationSummaryBubbleId,
includesToolResults]`.

```json
// FIXTURE (what the adapter expects): summary is a STRING
"latestConversationSummary": { "summary": "Fix the login bug" }

// LIVE STORE (modern Cursor): summary is a nested OBJECT
"latestConversationSummary": {
  "summary": {
    "summary": "<text>",
    "truncationLastBubbleIdInclusive": "<bid>",
    "clientShouldStartSendingFromInclusiveBubbleId": "<bid>",
    "previousConversationSummaryBubbleId": "<bid>",
    "includesToolResults": true
  },
  "lastBubbleId": "<bid>"
}
```
Both adapters read `latestConversationSummary.summary` and expect a String:
- Swift `CursorAdapter.swift:69-71` → `JSONLAdapterSupport.string(...)` which is
  `value as? String` (`CodexAdapter.swift:97-99`) → **returns `nil` when the
  value is a dict** → `summary` dropped.
- TS `cursor.ts:147` → `data.latestConversationSummary?.summary?.slice(0,200)` →
  `.slice` on an object → `undefined`.

**In all 6 live composers that have a summary, `summary.summary` is an OBJECT
(0 strings).** The modern Cursor summary is **never** ingested by the current
adapter. The string form only appears in the fixture.

**`context` shape** (every sub-array has a parallel `mentions.*` object). Engram
(TS only) infers cwd from `context.folderSelections[0].uri.fsPath`, else
`dirname(context.fileSelections[0].uri.fsPath)`:
```json
{
  "notepads": [], "composers": [], "quotes": [], "selectedCommits": [],
  "selectedPullRequests": [], "selectedImages": [], "folderSelections": [],
  "fileSelections": [], "selections": [], "terminalSelections": [],
  "selectedDocs": [], "externalLinks": [], "cursorRules": [],
  "mentions": {
    "gitDiff": [], "gitDiffFromBranchToMain": [], "usesCodebase": [],
    "useWeb": [], "useLinterErrors": [], "useDiffReview": [],
    "useContextPicking": [], "useRememberThis": [], "diffHistory": [],
    "folderSelections": {}, "fileSelections": {}, "cursorRules": {}
  }
}
```
Live presence: `folderSelections` non-empty **0/64**; `fileSelections` non-empty
**8/64**. `fileSelections[i]` carries keys `uri` (`{$mid, fsPath, external,
path, scheme}`) and `isCurrentFile`.

**`codeBlockData[fileURI][i]`** (CodeBlock, `_v:2`): `uri` (object), `version`
(int), `content` (string), `languageId` (string), `status`
(`accepted`/`completed`/`rejected`), `isNoOp` (bool),
`codeBlockDisplayPreference` (string), `bubbleId` (string, owning assistant
bubble), `codeBlockIdx` (int), `diffId` (string → `codeBlockDiff:<diffId>`).

---

## 6. Message & content schema

### 6.0 `fullConversationHeadersOnly[]` (ordered bubble manifest, modern format)

Lives inside `composerData`. An **ordered** list pointing to separate `bubbleId:`
rows — the authoritative **structural/insertion** order of bubbles within a
composer. Note: this is NOT a wall-clock chronological order; there is no
reliable per-message timestamp in this store at all (community RE marks date
filtering as "⚠️ Limited - no reliable timestamps")
([source](https://github.com/vltansky/cursor-chat-history-mcp/blob/main/docs/research.md)).

| Field | Type | Meaning | Example |
|---|---|---|---|
| `bubbleId` | string (uuid) | Local bubble id (joins to `bubbleId:<cid>:<bid>`) | `"e78092a4-…"` |
| `type` | int | `1`=user, `2`=assistant | `1` |
| `serverBubbleId` | string (uuid) | Server-side bubble id (assistant only) | `"550179b1-…"` |

```json
[
  { "bubbleId": "e78092a4-…", "type": 1 },
  { "bubbleId": "088216a7-…", "type": 2, "serverBubbleId": "550179b1-…" }
]
```

### 6.1 `bubbleId:<composerId>:<bubbleId>` — the message record

The richest record (~75 fields on user bubbles, ~90 on assistant). **Role
discriminator: `type` 1 = user, 2 = assistant** — no system or tool role (tool
I/O is nested inside assistant bubbles). Engram extracts only `type`, `text`
(fallback `rawText`), `timingInfo.clientStartTime`, and (assistant) `tokenCount`
(`CursorAdapter.swift:221-263`).

**6.1a Core / shared fields (both types):**

| Field | Type | Meaning | Presence | Consumed | Example |
|---|---|---|---|---|---|
| `_v` | int | Bubble schema version | all parseable (`2`×515) | no | `2` |
| `bubbleId` | string (uuid) | Message id | all | no (only in key) | `"02fcf474-…"` |
| `type` | int | `1`=user, `2`=assistant; else skipped | all | **yes (role)** | live: `{1:71, 2:444}` |
| `text` | string | Rendered message text → Engram `content` | partial | **yes (primary)** | `<redacted>` |
| `rawText` | string | Raw markdown source → fallback content | rare | **yes (fallback)** | `<redacted>` |
| `richText` | string | Lexical JSON of the message | most | no | — |
| `timingInfo` | object | Message timing (sub-object) | 71/515 bubbles, **all assistant (type 2); 0 user** | **yes (timestamp)** | see below |
| `tokenCount` | object | `{inputTokens, outputTokens}` | all | **yes (assistant usage)** | `{"inputTokens":0,"outputTokens":0}` |
| `tokenCountUpUntilHere` | int | Cumulative token count to this turn | some | no | `7309` |
| `tokenDetailsUpUntilHere` | array | `[{relativeWorkspacePath, count, lineCount}]` | some | no | `[]` |
| `context` / `contextPieces` | object/array | Per-bubble attached context | most | no | — |
| `checkpointId` | string | → `checkpointId:` FS snapshot | some | no | `<uuid>` |
| `cursorRules` | array | Active `.cursorrules` applied | most | no | `[]` |
| `supportedTools` | array | Tools available to the agent this turn | some | no | `array[18]` |
| `attachedCodeChunks`, `attachedFileCodeChunksUris`, `codebaseContextChunks` | array | Code context attached | most | no | `[]` |
| `attachedFolders`, `attachedFoldersListDirResults`, `attachedFoldersNew` | array | Folder context + `list_dir` results | most | no | `[]` |
| `gitDiffs`, `diffHistories`, `diffsSinceLastApply`, `diffsForCompressingFiles`, `fileDiffTrajectories` | array | Diff state for the turn | most | no | `[]` |
| `humanChanges`, `attachedHumanChanges` | array | User's manual edits in the window | most | no | `[]` |
| `deletedFiles`, `recentlyViewedFiles`, `recentLocationsHistory`, `relevantFiles`, `currentFileLocationData` | array/obj | Editor/file activity context | mostly | no | — |
| `lints`, `multiFileLinterErrors`, `approximateLintErrors` | array | Linter feedback | most | no | `[]` |
| `consoleLogs`, `interpreterResults`, `toolResults` | array | Execution output captured | most | no | `[]` |
| `suggestedCodeBlocks`, `assistantSuggestedDiffs`, `userResponsesToSuggestedCodeBlocks` | array | Suggested edits + accept/reject | most | no | `[]` |
| `images` | array | Pasted images | most | no | `[]` |
| `docsReferences`, `webReferences`, `externalLinks`, `aiWebSearchResults` | array | Doc/web grounding | some | no | `[]` |
| `notepads`, `pullRequests`, `commits`, `knowledgeItems`, `summarizedComposers` | array | More context surfaces | most | no | `[]` |
| `capabilities`, `capabilitiesRan`, `capabilityStatuses`, `capabilityContexts` | array/obj | Capability availability + run status | most | no | — |
| `existedPreviousTerminalCommand`, `existedSubsequentTerminalCommand` | bool | Terminal-context flags | some | no | `false` |
| `editTrailContexts` | array | Edit-trail context | some | no | `[]` |
| `unifiedMode` | string | Mode at this turn | most | no | `"agent"` |
| `isAgentic` | bool | Part of an agent run | all | no | `true` |

**6.1b Assistant-only (type 2) fields:**

| Field | Type | Meaning | Presence | Example |
|---|---|---|---|---|
| `serverBubbleId` | string (uuid) | Server-side bubble id | 244/444 | `<uuid>` |
| `usageUuid` | string (uuid) | Server usage/billing record id | 244/444 | `<uuid>` |
| `requestId` | string | Generation request id | 16/444 | `null`/`<uuid>` |
| `timingInfo` | object | Wall-clock timing; `clientStartTime` → Engram `timestamp` | 71/444 | see below |
| `toolFormerData` | object | **Tool call + result** (§7) | 278/444 | see §7 |
| `capabilityType` | int | Capability kind (all `15` observed) | 196/444 | `15` |
| `isThought` | bool | Reasoning/thinking-block flag. **Present on 196/444 but value is `false` on ALL of them — 0 bubbles have `isThought:true` live.** The 196 with the field present are exactly the `capabilityType:15` agent-iteration bubbles. | present 196/444, value `true` 0/444 | `false` |
| `allThinkingBlocks` | array | Reasoning blocks for the turn (empty in this store) | all | `[]` |
| `isCapabilityIteration` | bool | Intermediate agent step | 95/444 | `true` |
| `isChat` | bool | Plain-chat (non-agent) turn | 71/444 | `true` |
| `codeBlocks` | array | Code blocks emitted (§6.1c) | most | see below |
| `intermediateChunks` | array | Streaming chunks | 74/444 | — |
| `cachedConversationSummary`, `conversationSummary` | object | Rolling summary attached to turn | some | `{summary, lastBubbleId}` |
| `errorDetails` | object | `{generationUUID, message}` on failure | 4/444 | `{"generationUUID":"<uuid>","message":"Premature close"}` |
| `afterCheckpointId` | string | FS checkpoint after applying edits | 115/444 | `<uuid>` |
| `fileLinks`, `symbolLinks` | array | File/symbol references in output | some | `[]` |
| `isRefunded` | bool | Generation refunded (billing) | 220/444 | `false` |
| `mcpDescriptors` | array | MCP server/tool descriptors in scope | 16/444 | `[]` |

**6.1c `codeBlocks[i]` (assistant emitted code):** `_v` (int), `uri` (object —
`scheme,path,_fsPath,_formatted,…`), `version` (int), `codeBlockIdx` (int),
`content` (string), `languageId` (string), `unregistered` (bool).

**`timingInfo`** (all epoch ms):
```json
{ "clientStartTime": 1744430797410, "clientRpcSendTime": 1744430797434,
  "clientSettleTime": 1744430839587, "clientEndTime": 1744430839587 }
```

**Visibility rule (both adapters).** A bubble is emitted only if `type ∈ {1,2}`
AND `(text || rawText).trim()` is non-empty (`CursorAdapter.swift:221-240`,
`cursor.ts:123-131,207-211`). Assistant bubbles that are tool-only (empty `text`
but a `toolFormerData` payload) and thinking bubbles with empty `text` are
**dropped entirely** from counts and transcript.

**Sample (anonymized separate user bubble):**
```json
{
  "_v": 2,
  "type": 1,
  "bubbleId": "02fcf474-adc1-42b7-8933-c3904ebfc5d8",
  "text": "<redacted user message>",
  "richText": "<redacted lexical json>",
  "timingInfo": { "clientStartTime": 1744430797410, "clientRpcSendTime": 0, "clientSettleTime": 0, "clientEndTime": 0 },
  "tokenCount": { "inputTokens": 0, "outputTokens": 0 },
  "context": { "fileSelections": [], "folderSelections": [], "terminalFiles": [] },
  "checkpointId": "<uuid>",
  "supportedTools": [ /* 18 entries */ ],
  "toolResults": [], "lints": [], "gitDiffs": [], "images": []
}
```

---

## 7. Tool calls & results — `toolFormerData` (nested in assistant bubble)

Cursor stores **the tool call AND its result in the SAME object** inside the
bubble that issued it — there is no separate "tool result" record/role. It
**usually lives on the assistant bubble, but 13/291 live payloads are on USER
(type-1) bubbles** (278 assistant + 13 user), so "nested in the assistant
bubble" is not strictly true. `toolCallId` is the join key (also used in
`messageRequestContext`). Verified keys live (11):
`[tool, toolCallId, status, rawArgs, name, additionalData, params, result,
userDecision, toolIndex, modelCallId]`.

| Field | Type | Meaning | Example |
|---|---|---|---|
| `tool` | int | Tool enum id | `6` (list_dir), `5` (read_file), `7` (edit_file), `15` (run_terminal_cmd), `9` (codebase_search), `18` (web_search), `19` (MCP) |
| `name` | string | Tool name | `"edit_file"`, `"read_file"`, `"run_terminal_cmd"`, `"web_search"`, `"mcp_mcp-safeline_get_attack_events"` |
| `toolCallId` | string | **Join key** for the call/result pair | `"<str 40>"` |
| `status` | string | `"completed"` / `"cancelled"` (`null` when never executed) | `"completed"` |
| `params` | string (JSON) | Parsed tool arguments | `"{\"directoryPath\":\".\"}"` |
| `rawArgs` | string | Raw arg string from the model | `"<str 32>"` |
| `result` | string (JSON/text) | **Tool output** colocated with the call | `"<str 626>"` |
| `additionalData` | object | Tool-specific extras | `{}` |
| `userDecision` | string | User accept/reject of the tool action | 171 live | `"accepted"` |
| `toolIndex` | int | Tool index within the turn | 5 live | `0` |
| `modelCallId` | string | Model-side call id | 5 live | `"<id>"` |

**Live `name` distribution** (291 toolFormerData payloads = 278 assistant + 13 user): `edit_file` 115,
`(blank — MCP/unnamed)` 95, `run_terminal_cmd` 49, `read_file` 16, `list_dir` 7,
`mcp_mcp-safeline_get_attack_events` 3, `web_search` 2,
`mcp_mcp-safeline_create_blacklist_rule` 2, `codebase_search` 2.

```json
{
  "tool": 6, "toolCallId": "<id40>", "status": "completed",
  "name": "list_dir", "rawArgs": "<str 32>", "params": "{\"directoryPath\":\".\"}",
  "additionalData": {}, "result": "<str 626>"
}
```

**Engram does NOT parse `toolFormerData`.** `toolCalls` is always `nil`
(`CursorAdapter.swift:149`); `toolMessageCount` is hardcoded `0`
(`CursorAdapter.swift:91`, `cursor.ts:145`). Tool-only assistant turns vanish
from the transcript and counts.

---

## 8. Reasoning / thinking

**Reasoning is essentially not present in this store.** The `isThought` flag
is **present on 196/444 assistant bubbles but its value is `false` on every one
— 0 bubbles have `isThought:true` live** (the 196 are exactly the
`capabilityType:15` agent-iteration bubbles where the flag is emitted=false).
`allThinkingBlocks` is **empty `[]` across all 444 assistant bubbles**. So both
the thinking-flag and the structured-reasoning array are effectively unused here
(newer Cursor versions may populate them). `intermediateChunks` holds streaming
fragments (74/444). Either way Engram consumes none of it; thinking bubbles with
empty `text` are dropped, so they never appear in counts or transcript.

---

## 9. Token usage & cost

Three usage surfaces exist; Engram consumes only the per-message one (Swift only).

| Surface | Location | Type | Consumed |
|---|---|---|---|
| Per-message tokens | `bubble.tokenCount = {inputTokens, outputTokens}` | object | **Swift only** → message `usage` |
| Cumulative tokens | `bubble.tokenCountUpUntilHere` (int) + `tokenDetailsUpUntilHere` ([{relativeWorkspacePath, count, lineCount}]) | int/array | no |
| Per-session cost | `composerData.usageData = {model → {costInCents, amount}}` + `composerData.tokenCount` (int) | object/int | no |

- **Swift** maps per-bubble `tokenCount → TokenUsage` for assistant messages
  (`CursorAdapter.swift:150-152, 253-263`), with `cacheReadTokens=0`,
  `cacheCreationTokens=0`, and a guard that **drops zero-token usage**
  (`inputTokens>0 || outputTokens>0`). Live sample bubbles often have
  `{"inputTokens":0,"outputTokens":0}` → no usage emitted.
- **TS does NOT emit usage at all** — a Swift↔TS behavioral divergence. The
  parity fixture happens to dodge it because its assistant bubble has no
  `tokenCount`.
- **`composerData.usageData`** is frequently `{}` live (no cost recorded) and is
  **ignored** by both adapters along with `composerData.tokenCount`.

---

## 10. Subagent / parent-child / dispatch

**N/A for Cursor (adapter level).** The Cursor adapter sets
`parentSessionId`, `suggestedParentId`, `agentRole`, `originator`, and `origin`
all to `nil` (`CursorAdapter.swift:97-104`). Cursor has no Gemini-style
`.engram.json` sidecar and no path-based subagent linkage. Cursor's own internal
fan-out signals exist but are not consumed: `composer.composerHeaders` carries
`numSubComposers` / `isBestOfNSubcomposer`, and `agentKv:blob:*` holds raw agent
transcripts — none are read. Any parent/child linkage would be applied
downstream by Engram's heuristic pipeline (Layer 2), not by this adapter.

---

## 11. Summary / compaction

Cursor maintains a rolling AI-generated summary at the session level
(`composerData.latestConversationSummary`) and per-turn
(`bubble.cachedConversationSummary` / `conversationSummary`). The session summary
encodes its own compaction boundaries:
`truncationLastBubbleIdInclusive`,
`clientShouldStartSendingFromInclusiveBubbleId`,
`previousConversationSummaryBubbleId`, and `includesToolResults` — i.e. Cursor
truncates older bubbles and replaces them with the summary when re-sending
context to the model.

**Engram intends to ingest `latestConversationSummary.summary` (≤200 chars) into
`summary`, but the modern nested-object shape defeats it** — see the §5 / §15
drift bug. Effectively, summary is **never ingested** from the live modern store
(0/6 strings); Engram falls back to the first user message for any preview/title.

---

## 12. SQLite / DB internals

**Two tables, both `key`/`value` KV** (live DDL):
```sql
CREATE TABLE ItemTable    (key TEXT UNIQUE ON CONFLICT REPLACE, value BLOB);
CREATE TABLE cursorDiskKV (key TEXT UNIQUE ON CONFLICT REPLACE, value BLOB);
```
- **No PRIMARY KEY** declared; uniqueness + upsert via
  `UNIQUE ... ON CONFLICT REPLACE` on `key`. Joins are emulated by **key-prefix
  string matching** (`LIKE 'composerData:%'`, `LIKE 'bubbleId:<cid>:%'`), not SQL
  foreign keys. There is no row ordering column other than the implicit `rowid`,
  which both adapters rely on for message order (`ORDER BY rowid ASC`).
- `value` is declared `BLOB` but stores UTF-8 JSON text (parsed via
  `JSON.parse` / `Phase4AdapterSupport.jsonObject(from:)`).
- **Fixture DDL differs** (`tests/fixtures/cursor/state.vscdb`):
  `CREATE TABLE cursorDiskKV (key TEXT PRIMARY KEY, value TEXT)` — uses
  `PRIMARY KEY` + `TEXT` rather than the live `UNIQUE ON CONFLICT REPLACE` +
  `BLOB`. Functionally equivalent for reads; flag for any DDL-sensitive tooling.

**`ItemTable` singleton keys (IGNORED by Engram):** `composer.composerHeaders`
(global composer catalog — see below), `composer.composerData` (per-workspace
DB only — composer→folder map), `composer.planMigrationToHomeDirCompleted`,
`workbench.panel.aichat.view.aichat.chatdata`, many `workbench.panel.*chat*` UI
flags, `chat.workspaceTransfer`.

**`composer.composerHeaders` (ItemTable) → `{ allComposers: [Header] }`** — the
cross-session catalog Engram does NOT use (it enumerates `composerData:%`
directly). Header fields: `composerId`, `type` (`"head"`), `createdAt` /
`lastUpdatedAt` (ms), `unifiedMode` / `forceMode`, `totalLinesAdded` /
`totalLinesRemoved`, `hasUnreadMessages`, `hasBlockingPendingActions`,
`hasPendingPlan`, `isArchived`, `isDraft`, `isSpec`, `isProject`, `isWorktree`,
`isBestOfNSubcomposer`, `numSubComposers`, `referencedPlans`, `trackedGitRepos`,
`workspaceIdentifier` (`{id}`), `draftTarget` (`{type, environment}`),
`worktreeStartedReadOnly`, `hasBeenInSidebar`.

**Workspace DB** `ItemTable['composer.composerData']` =
`{ allComposers:[{composerId,type,createdAt,unifiedMode,forceMode}],
selectedComposerId, selectedChatId, hasMigratedChatData, … }` — the only
composer→workspace-folder mapping. Not crawled by `CursorAdapter`.

---

## 13. Auxiliary files

These `cursorDiskKV` namespaces and on-disk files carry rich agent state that
Engram ignores entirely.

**`checkpointId:<cid>:<id>`** (369 rows) — filesystem snapshot for rollback,
referenced by `bubble.checkpointId` / `afterCheckpointId`:
```json
{ "files": [], "nonExistentFiles": [], "newlyCreatedFolders": [],
  "activeInlineDiffs": [], "inlineDiffNewlyCreatedResources": { "files": [], "folders": [] } }
```

**`codeBlockDiff:<id>:<id>`** (174 rows) — line-range diff vs base v0, referenced
by `codeBlockData[…].diffId`:
```json
{ "originalModelDiffWrtV0": [],
  "newModelDiffWrtV0": [ { "original": { "startLineNumber":778, "endLineNumberExclusive":821 }, "modified": ["<str 51>"] } ] }
```

**`agentKv:blob:<sha256>`** (46 rows) — content-addressed raw provider messages
(the literal `{role,content}` sent to the model; distinct from bubbles which are
the UI/render layer). Community RE describes agentKv as the request/provenance
axis carrying assistant text, tool traffic, and reasoning blocks, keyed inside
the value by `providerOptions.cursor.requestId`
([source](https://vibe-replay.com/blog/cursor-local-storage/)). The SHA-256 key
is **not** joined to a composerId, so the blob→composer mapping is not
established from the key alone; any join would have to go through a `requestId` /
provenance field inside the blob value (plausible but not demonstrated end-to-end
by any public source):
```json
{ "role": "user", "content": "<user_info>\nOS Version: …\nWorkspace Path: /…/.cursor\n…</user_info>" }
```

**`messageRequestContext:<cid>:<bid>`** (24 rows) — per-request context bound to
a bubble: `cursorRules` (array), `attachedFoldersListDirResults` (array),
`summarizedComposers` (array), `terminalFiles` (array).

**`composerVirtualRowHeights:<cid>:_recentIds`** (1 row) — UI virtual-list render
cache.

**On-disk auxiliary (outside the global DB):**
- `workspaceStorage/<hash>/state.vscdb` + `.backup` — per-workspace UI state /
  pointer index (composer→folder map; not crawled).
- `workspaceStorage/<hash>/workspace.json` — hash→folder URI.
- `workspaceStorage/<hash>/anysphere.cursor-retrieval/` — codebase-index ext state.
- `History/` — VS Code per-file edit history (unrelated to chat).

---

## 14. Engram mapping

**Adapter registration.** Source enum `case cursor`
(`macos/Shared/EngramCore/Adapters/SessionAdapter.swift:17`); constructed in the
default factory at `SessionAdapterFactory.swift:23` and `:68`, and in
`macos/Engram/Core/MessageParser.swift:126` (one of the 17 default adapters).
TS class `CursorAdapter` (`src/adapters/cursor.ts:32`).

### Session-level (`NormalizedSessionInfo`)

| Engram field | Cursor source | Swift file:line | TS file:line | Notes / discrepancy |
|---|---|---|---|---|
| `id` | `composerData.composerId` (fallback: locator composerId) | `CursorAdapter.swift:81` | `cursor.ts:134` | UUID |
| `source` | constant `.cursor` / `'cursor'` | `:82` | `:135` | — |
| `startTime` | `createdAt` → else first visible bubble `timingInfo.clientStartTime` → else `lastUpdatedAt` → else 0 | `:64-67, 83` | `:136` | **Swift has richer fallback chain; TS uses `createdAt` only.** |
| `endTime` | `lastUpdatedAt` (only if ≠ createdAt, else `nil`) | `:68, 84` | `:137-140` | — |
| `cwd` | **Swift: hardcoded `""`**; TS: `inferCwd` = first folderSelection.fsPath, else `dirname(first fileSelection.fsPath)`, else `""` | `:85` | `:141, 236-242` | **DISCREPANCY: Swift never infers cwd.** Live: folderSelections 0/64, fileSelections 8/64, so TS emits a dir for those 8; Swift emits `""` for all. |
| `project` | always `nil` | `:86` | (n/a in TS shape) | Composers not bound to a workspace |
| `model` | always `nil` | `:87` | (absent) | Not extracted |
| `messageCount` | userCount + assistantCount (visible bubbles) | `:88` | `:142` | — |
| `userMessageCount` | count of visible `type==1` | `:61, 89` | `:129, 143` | — |
| `assistantMessageCount` | count of visible `type==2` | `:62, 90` | `:130, 144` | — |
| `toolMessageCount` | **hardcoded 0** | `:91` | `:145` | `toolFormerData` not counted |
| `systemMessageCount` | **hardcoded 0** | `:92` | `:146` | Cursor has no system bubbles |
| `summary` | `latestConversationSummary.summary` truncated to 200 chars | `:69-71, 93` | `:147` | **Modern store: nested object → yields `nil` (§5 bug)** |
| `filePath` | the virtual locator `<db>?composer=<id>` | `:94` | `:148` | — |
| `sizeBytes` | per-session = `len(composerValue)` + Σ `len(bubble rows)` | `:72-77, 95` | `:99-119, 149` | NOT the whole 28 MB file (parity comment) |
| `indexedAt` | `nil` | `:96` | (absent) | Set downstream |
| `agentRole`/`originator`/`origin`/`parentSessionId`/`suggestedParentId`/`tier`/`qualityScore`/`summaryMessageCount` | all `nil` | `:97-104` | (absent) | Set by downstream pipeline |

### Per-message (`NormalizedMessage`)

| Engram field | Cursor source | Swift file:line | TS file:line |
|---|---|---|---|
| `role` | `type` 1→user, 2→assistant | `:224-232` | `:207-208` |
| `content` | `text` ‖ `rawText` (non-empty) | `:234-235` | `:210` |
| `timestamp` | `timingInfo.clientStartTime` (ms→ISO) | `:141-144` | `:217, 221` |
| `usage` | assistant only: `{inputTokens,outputTokens}` from `tokenCount` (cache=0; zero-usage dropped) | `:150-152, 253-263` | **not mapped in TS** |
| `toolCalls` | always `nil` | `:149` | (absent) |

**Discovery / enumeration pipeline:**
1. `detect()` — true iff `globalStorage/state.vscdb` exists
   (`CursorAdapter.swift:16-18`, `cursor.ts:50-57`).
2. `listSessionLocators()` (Swift) / `listSessionFiles()` (TS) — open read-only,
   `SELECT key, value FROM cursorDiskKV WHERE key LIKE 'composerData:%'`, parse
   each, take `composerId`, skip empty, emit virtual locator
   `<dbPath>?composer=<composerId>` (`CursorAdapter.swift:20-36`,
   `cursor.ts:59-84`).
3. `parseSessionInfo(locator)` — split on `?composer=` (`parseVirtualLocator`,
   `CursorAdapter.swift:175-181`; `parsePath`, `cursor.ts:244-254`), fetch
   `composerData:<id>`, resolve bubbles via the two-format fallback, count visible
   user/assistant bubbles, compute timestamps + per-session size.
4. `streamMessages(locator, options)` — same fetch + fallback, map each visible
   bubble to `NormalizedMessage`, apply offset/limit window.
5. `isAccessible(locator)` — cheap probe
   `SELECT 1 FROM cursorDiskKV WHERE key='composerData:<id>' LIMIT 1`, cached
   (`CursorAdapter.swift:163-173`, `cursor.ts:256-276`).

**Dropped entirely by Engram:** `name` (chat title), modern
`latestConversationSummary.summary` object, `toolFormerData` (all tool
calls/results), `codeBlocks`/`codeBlockData`/`codeBlockDiff` (all edits/diffs),
`isThought`/`allThinkingBlocks` (reasoning), `usageData`/`tokenCountUpUntilHere`
(cost/cumulative tokens), `checkpointId`, `agentKv`, `messageRequestContext`,
`serverBubbleId`/`usageUuid`, `errorDetails`, `model`, sub-composer/agent
structure, all of `ItemTable`, and the `workspaceStorage/` per-workspace DBs.

---

## 15. Lineage, gotchas, version drift & edge cases

### Shared format lineage with sibling tools

Cursor is a **VS Code fork**, so one might expect it to share storage with the
VS Code / Copilot / Cline family. **It does not — Cursor is a lineage outlier.**
Of the six VS Code-family adapters, **only `CursorAdapter` reads
`state.vscdb`/`cursorDiskKV`**:

| Tool | Engram adapter | Storage tech & root | Shared with Cursor? |
|---|---|---|---|
| **Cursor** | `CursorAdapter` | SQLite `globalStorage/state.vscdb` → `cursorDiskKV` (`composerData:` / `bubbleId:`) | — (baseline) |
| **VS Code** (Copilot Chat) | `VsCodeAdapter` | crawls `Code/User/workspaceStorage/<hash>/` (vscdb-family, per-workspace) | **Container family yes (`.vscdb`), schema NO** |
| **GitHub Copilot CLI** | `CopilotAdapter` | `~/.copilot/session-state/<id>/events.jsonl` + `workspace.yaml` | **No** — JSONL |
| **Cline** | `ClineAdapter` | `~/.cline/data/tasks/<id>/ui_messages.json` | **No** — per-task JSON |
| **Windsurf** (Codeium Cascade) | `WindsurfAdapter` | `.codeium/windsurf/…` → `.engram/cache/windsurf/<cascadeId>.jsonl` | **No** — Cascade JSONL cache |
| **Antigravity** (Gemini) | `AntigravityAdapter` | `.gemini/antigravity/…` / `.gemini/antigravity-cli/brain` | **No** — Cascade/CLI JSONL |

Takeaways:
- The shared artifact is the **SQLite `state.vscdb` container** inherited from VS
  Code, but Cursor invented its own table (`cursorDiskKV`) and
  `composerData:`/`bubbleId:` key convention. VS Code / Copilot Chat keep chat in
  the standard `ItemTable`/`workspaceStorage` instead. The "VS Code fork"
  relationship is **container-level only, not schema-level** — an adapter written
  for VS Code's chat store cannot read Cursor's, and vice versa.
- This contrasts with the Gemini CLI ↔ Qwen ↔ iFlow family (true JSONL schema
  reuse). Cursor's nominal siblings each diverged to a different storage tech, so
  Engram needs six distinct adapters for one editor family.

### Gotchas, version drift, edge cases

1. **Message order relies on `rowid`, not the header manifest.** Engram orders
   separate bubbles by SQLite `rowid ASC` (`CursorAdapter.swift:206`,
   `cursor.ts:192`), NOT by `fullConversationHeadersOnly[]`. The manifest is the
   authoritative **structural/insertion** order of bubbles within a composer (not
   a wall-clock order — this store has "no reliable timestamps"); community
   guidance uses `ROWID` only for ordering whole CONVERSATIONS by recency, because
   neither UUIDs nor timestamps are chronological. No public source confirms
   `rowid` is a safe per-BUBBLE order, so relying on it (instead of the manifest)
   for a re-inserted / edited bubble is a plausible-but-unverified risk
   ([source](https://github.com/vltansky/cursor-chat-history-mcp/blob/main/docs/research.md)).
2. **Summary nesting drift (HIGH IMPACT).** Modern store nests `summary` as an
   object (`{summary, truncationLastBubbleIdInclusive, …}`); both adapters expect
   a string → summary silently dropped for ALL live sessions (**0/6 strings**).
   The fixture still encodes the old string form, so there is **no regression
   guard** for the object form.
3. **Title (`name`) ignored** despite being present (8/64) and the only reliable
   title signal once summaries are dropped.
4. **Format trichotomy + NULL.** Live: 4 inline / 4 headers-only / 51 empty /
   5 NULL (64 total). **~80% are empty drafts** that emit 0-message sessions; the
   adapter does not filter them (relies on downstream `tier=skip`/`lite`).
5. **cwd is `""` in the shipped Swift product** (TS-only inference). Even TS
   would emit `""` for most: folderSelections are 0/64 live; only the 8 composers
   with fileSelections would get a `dirname`.
6. **Tool turns dropped.** `toolFormerData` carries real tool calls
   (`includesToolResults:true` in summaries), but `toolMessageCount`/`toolCalls`
   are zeroed; tool-only assistant turns (empty `text`) vanish from transcript and
   counts.
7. **Sparse timestamps.** Only assistant bubbles carry `timingInfo` (exactly
   71/444, all type 2); user bubbles have none (0), so Engram emits
   `timestamp:nil` for them. Swift falls back to the first-bubble timestamp then `createdAt` for the
   session `startTime`, but individual messages without `timingInfo` get a `nil`
   timestamp.
8. **Token usage parity gap.** Swift emits per-message assistant usage from
   `tokenCount`; TS does not — an untested Swift↔TS divergence. The parity
   fixture dodges it (its bubble lacks `tokenCount`). Live bubbles are often
   `{0,0}` → no usage emitted anyway (zero-usage guard).
9. **NULL `composerData` values (5/64)** and malformed JSON are silently skipped
   (guard at `CursorAdapter.swift:27`, `compactMap` in TS).
10. **Locator coupling.** Locator is `<dbPath>?composer=<id>`; parsing splits on
    the literal `?composer=` (`CursorAdapter.swift:175-181`, `cursor.ts:248`). A
    composerId containing that substring would break parsing (not observed,
    unvalidated).
11. **Reasoning effectively absent.** `allThinkingBlocks` is `[]` across all 444
    assistant bubbles, and `isThought` is **present on 196 but `false` on every
    one (0 are `true`)** — the doc previously conflated "field present on 196"
    with "value true on 196". The structured reasoning-block schema could not be
    confirmed from this store; newer Cursor versions DO populate reasoning —
    community RE documents `thinkingDurationMs` on bubble payloads (sample value
    21322) and reasoning blocks within agentKv message objects, so the empty
    live store is a version snapshot
    ([source](https://vibe-replay.com/blog/cursor-local-storage/)).
12. **Tool / capability enums unmapped.** `capabilityType` is always `15` live;
    observed `tool` ints are `{1,5,6,7,9,15,18,19}` — the full name mapping is
    not derivable from a single store.

### Open questions (web-checked 2026-06-21)

- **Modern nested-summary form.** Confirmed (official): the object nesting is
  real product behavior, not a doc artifact. Community RE types declare
  `latestConversationSummary` as `{ summary: { summary: string } }` and read the
  text at `latestConversationSummary.summary.summary`; an adapter that reads
  `latestConversationSummary.summary` and expects a String gets an object and
  drops it — exactly the live finding. Whether Cursor regards the nesting as a
  bug vs intentional is not stated by any source (the format is undocumented)
  ([source](https://github.com/vltansky/cursor-chat-history-mcp/blob/main/src/database/types.ts)).
- **`composerData.name` as title.** Confirmed (official): `name` IS the
  conversation title in the modern format (vltansky types: `name?: string; //
  Conversation title (Modern format only)`, surfaced as `title?`; vibe-replay
  lists `"name"` as the chat title). The factual premise is verified; whether
  Engram SHOULD ingest it is an Engram-internal design decision
  ([source](https://github.com/vltansky/cursor-chat-history-mcp/blob/main/src/database/types.ts), [source](https://vibe-replay.com/blog/cursor-local-storage/)).
- **Swift `cwd=""` vs TS inference.** (Engram-internal design - not
  web-verifiable.) The format premise is verified though: `context.fileSelections[].uri.fsPath/path`
  exists on composers and bubbles, so cwd inference from those fields is
  technically possible — consistent with the TS approach
  ([source](https://github.com/vltansky/cursor-chat-history-mcp/blob/main/src/database/types.ts)).
- **Intended session-level cost source.** Confirmed (official) that token/usage
  is frequently absent or zero (vibe-replay: "many sessions still have no usable
  token snapshots"; codeburn #114: a populated `state.vscdb` with 87k agentKv /
  69k bubbleId rows still yields ZERO usage on macOS). But NO public source
  documents which field is canonical (`composerData.usageData` vs
  `composerData.tokenCount` vs summed per-bubble `tokenCount`); Cursor does not
  document it, so the canonical source remains unknown
  ([source](https://vibe-replay.com/blog/cursor-local-storage/), [source](https://github.com/getagentseal/codeburn/issues/114)).
- **Older workspace-scoped composers missed by the global-DB-only adapter.**
  Confirmed (official): partially confirmed — a real legacy-only gap exists,
  magnitude unknown. Modern composers are global-only (content in `globalStorage`
  `cursorDiskKV`; workspace DB holds only metadata/pointers), so the global-only
  read is safe for modern data. But legacy-era chat stored under the per-workspace
  `ItemTable` key `workbench.panel.aichat.view.aichat.chatdata` can live ONLY in
  `workspaceStorage/` and would be missed
  ([source](https://github.com/S2thend/cursor-history/blob/main/CLAUDE.md), [source](https://dasarpai.com/dsblog/cursor-chat-architecture-data-flow-storage/)).
- **`agentKv:blob` → composer mapping.** Confirmed (official) that agentKv blobs
  are request/provenance-scoped raw `{role,content}` objects distinct from the
  bubble (UI/render) layer, so the linkage is via a within-value `requestId` /
  provenance field, not the SHA-256 key — consistent with "not establishable from
  the key alone." A within-value `requestId` join is plausible but no source
  demonstrates a complete blob→composer reconstruction
  ([source](https://vibe-replay.com/blog/cursor-local-storage/)).
- **Does `toolFormerData` appear on user (type 1) bubbles?** (web-checked
  2026-06-21: no authoritative source found.) Community sources typically
  illustrate `toolFormerData` on assistant bubbles (S2thend: "toolFormerData
  appears on assistant bubbles") and vibe-replay says each `bubbleId:*` row CAN
  carry it without restricting to assistant — neither confirms nor refutes the
  live store's 13/291 user-bubble observation; no external dataset to cross-check.

---

## 16. Appendix: real anonymized samples

### `cursorDiskKV` schema (live)
```sql
CREATE TABLE ItemTable    (key TEXT UNIQUE ON CONFLICT REPLACE, value BLOB);
CREATE TABLE cursorDiskKV (key TEXT UNIQUE ON CONFLICT REPLACE, value BLOB);
```

### `composerData:<composerId>` (inline format, top-level keys)
```json
{
  "_v": 3,
  "composerId": "0066a5aa-1757-44bf-a7c4-1a3d6ee3c790",
  "name": "<chat title>",
  "text": "",
  "richText": "<lexical json>",
  "status": "completed",
  "createdAt": 1738226420089,
  "lastUpdatedAt": 1744430839587,
  "conversation": [ { "type": 1, "text": "<redacted>", "...": "..." } ],
  "context": { "folderSelections": [], "fileSelections": [ { "uri": { "fsPath": "<redacted/path>", "scheme": "file" }, "isCurrentFile": true } ], "mentions": { "...": "..." } },
  "codeBlockData": { "file:///<redacted>": [ { "_v": 2, "version": 0, "content": "<redacted>", "languageId": "json", "status": "accepted", "bubbleId": "<uuid>", "codeBlockIdx": 0, "diffId": "<uuid>" } ] },
  "originalModelLines": {},
  "usageData": {},
  "unifiedMode": "agent",
  "forceMode": "edit",
  "isAgentic": true
}
```

### `composerData.latestConversationSummary` (modern, nested object — drift)
```json
{
  "summary": {
    "summary": "<redacted summary text>",
    "truncationLastBubbleIdInclusive": "<bid>",
    "clientShouldStartSendingFromInclusiveBubbleId": "<bid>",
    "previousConversationSummaryBubbleId": "<bid>",
    "includesToolResults": true
  },
  "lastBubbleId": "<bid>"
}
```

### `composerData.fullConversationHeadersOnly` (modern manifest)
```json
[
  { "bubbleId": "e78092a4-…", "type": 1 },
  { "bubbleId": "088216a7-…", "type": 2, "serverBubbleId": "550179b1-…" }
]
```

### `bubbleId:<cid>:<bid>` (user, type 1)
```json
{
  "_v": 2,
  "type": 1,
  "bubbleId": "02fcf474-adc1-42b7-8933-c3904ebfc5d8",
  "text": "<redacted user message>",
  "richText": "<redacted lexical json>",
  "timingInfo": { "clientStartTime": 1744430797410, "clientRpcSendTime": 0, "clientSettleTime": 0, "clientEndTime": 0 },
  "tokenCount": { "inputTokens": 0, "outputTokens": 0 },
  "context": { "fileSelections": [], "folderSelections": [], "terminalFiles": [] },
  "checkpointId": "<uuid>",
  "supportedTools": [ "...18 entries..." ],
  "toolResults": [], "lints": [], "gitDiffs": [], "images": []
}
```

### `bubbleId:<cid>:<bid>` (assistant, type 2, with tool call)
```json
{
  "_v": 2,
  "type": 2,
  "bubbleId": "<uuid>",
  "serverBubbleId": "<uuid>",
  "usageUuid": "<uuid>",
  "text": "",
  "isAgentic": true,
  "isThought": false,
  "capabilityType": 15,
  "timingInfo": { "clientStartTime": 1744430797410, "clientRpcSendTime": 1744430797434, "clientSettleTime": 1744430839587, "clientEndTime": 1744430839587 },
  "tokenCount": { "inputTokens": 0, "outputTokens": 0 },
  "toolFormerData": {
    "tool": 6, "toolCallId": "<id40>", "status": "completed",
    "name": "list_dir", "rawArgs": "<str 32>", "params": "{\"directoryPath\":\".\"}",
    "additionalData": {}, "result": "<str 626>"
  },
  "codeBlocks": [], "allThinkingBlocks": [], "afterCheckpointId": "<uuid>", "isRefunded": false
}
```

### `checkpointId:<cid>:<id>`
```json
{ "files": [], "nonExistentFiles": [], "newlyCreatedFolders": [],
  "activeInlineDiffs": [], "inlineDiffNewlyCreatedResources": { "files": [], "folders": [] } }
```

### `codeBlockDiff:<id>:<id>`
```json
{ "originalModelDiffWrtV0": [],
  "newModelDiffWrtV0": [ { "original": { "startLineNumber": 778, "endLineNumberExclusive": 821 }, "modified": ["<str 51>"] } ] }
```

### `agentKv:blob:<sha256>`
```json
{ "role": "user", "content": "<user_info>\nOS Version: …\nWorkspace Path: /…/.cursor\n…</user_info>" }
```

### `messageRequestContext:<cid>:<bid>`
```json
{ "cursorRules": [], "attachedFoldersListDirResults": [], "summarizedComposers": [], "terminalFiles": [] }
```

### `ItemTable['composer.composerHeaders']` (catalog header element)
```json
{
  "composerId": "<uuid>", "type": "head",
  "createdAt": 1778141144676, "lastUpdatedAt": 1778141200000,
  "unifiedMode": "agent", "forceMode": "edit",
  "totalLinesAdded": 0, "totalLinesRemoved": 0,
  "hasUnreadMessages": false, "isArchived": false, "isDraft": false,
  "isSpec": false, "isProject": false, "isWorktree": false, "isBestOfNSubcomposer": false,
  "numSubComposers": 0, "referencedPlans": [], "trackedGitRepos": [],
  "workspaceIdentifier": { "id": "empty-window" },
  "draftTarget": { "type": "existing", "environment": "<str>" }
}
```

### Engram virtual locator
```
/Users/<user>/Library/Application Support/Cursor/User/globalStorage/state.vscdb?composer=0066a5aa-1757-44bf-a7c4-1a3d6ee3c790
```

---

## References (official sources)

Cursor's on-disk format is NOT officially documented — the only official export
surface is Shared Transcripts (Teams/Enterprise). The framing and field-level
claims below were cross-checked against community reverse-engineering on
2026-06-21 (web_access_ok=true):

- [Cursor Docs — Shared transcripts](https://cursor.com/docs/agent/chat/export) — only official export surface; on-disk format undocumented.
- [vltansky/cursor-chat-history-mcp — src/database/types.ts](https://github.com/vltansky/cursor-chat-history-mcp/blob/main/src/database/types.ts) — TypeScript interfaces for ComposerData/Bubble (authoritative community RE).
- [vltansky/cursor-chat-history-mcp — docs/research.md](https://github.com/vltansky/cursor-chat-history-mcp/blob/main/docs/research.md) — cursorDiskKV key patterns, ROWID ordering, formats.
- [vibe-replay — What Does Cursor Store on Your Machine?](https://vibe-replay.com/blog/cursor-local-storage/) — deep dive on state.vscdb, agentKv, thinkingDurationMs, token snapshots.
- [dasarpai — Cursor Chat: Architecture, Data Flow & Storage](https://dasarpai.com/dsblog/cursor-chat-architecture-data-flow-storage/) — ItemTable keys, OS paths, legacy chatdata key.
- [S2thend/cursor-history — CLAUDE.md](https://github.com/S2thend/cursor-history/blob/main/CLAUDE.md) — workspace vs global DB split, toolFormerData fields.
- [getagentseal/codeburn Issue #114](https://github.com/getagentseal/codeburn/issues/114) — zero usage despite populated state.vscdb on macOS.
